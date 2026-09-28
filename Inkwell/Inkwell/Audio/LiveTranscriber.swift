import Foundation
import AVFoundation
import Speech
import CoreMedia
import Synchronization

/// On-device transcription with Apple's SpeechAnalyzer (PRD §7.6).
///
/// Buffers come from the recorder's single input tap from the very first sample. Recording
/// starts immediately; until the model is ready the tap's buffers are queued here, then
/// drained into the analyzer in order — so transcript times are recording-relative and no
/// audio is lost to setup. Only finals are persisted, appended to the JSON as they arrive.
nonisolated final class LiveTranscriber: @unchecked Sendable {
    enum Engine: String { case speech = "SpeechTranscriber", dictation = "DictationTranscriber" }

    let noteID: UUID
    let recordingID: UUID
    let locale: Locale

    /// Everything the audio thread touches, behind one lock.
    private struct Feed {
        var pending: [AVAudioPCMBuffer] = []
        var pendingFrames: AVAudioFramePosition = 0
        var converter: AVAudioConverter?
        var format: AVAudioFormat?
        var builder: AsyncStream<AnalyzerInput>.Continuation?
        var ready = false
        var closed = false
    }
    // NSLock (not Mutex): the state holds non-Sendable AVFoundation objects shared with the tap thread.
    private let feedLock = NSLock()
    private var feedState = Feed()
    /// Cap on audio queued while the model loads (~2 min at 48 kHz); older audio is transcribed via backfill.
    private static let maxPendingFrames: AVAudioFramePosition = 48_000 * 120

    private var module: (any SpeechModule)?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var transcript: Transcript
    private let onFinal: @Sendable (Transcript.Segment) -> Void
    private let onVolatile: @Sendable (String) -> Void
    private var lastVolatileSent = Date.distantPast

    init(noteID: UUID, recordingID: UUID, locale: Locale,
         onFinal: @escaping @Sendable (Transcript.Segment) -> Void,
         onVolatile: @escaping @Sendable (String) -> Void) {
        self.noteID = noteID
        self.recordingID = recordingID
        self.locale = locale
        self.onFinal = onFinal
        self.onVolatile = onVolatile
        self.transcript = Transcript(recordingId: recordingID.uuidString, locale: locale.identifier(.bcp47),
                                     engine: Engine.speech.rawValue, segments: [])
    }

    // MARK: - Module setup

    /// Builds the best available transcriber module for `locale`.
    static func makeModule(locale: Locale, volatile: Bool) async -> (any SpeechModule, Engine)? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            // .fastResults trades a little accuracy in the *volatile* text for lower latency;
            // finals are unaffected (PRD §7.6 asks for words within ~1 s).
            let t = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                      reportingOptions: volatile ? [.volatileResults, .fastResults] : [],
                                      attributeOptions: [.audioTimeRange])
            return (t, .speech)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let t = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: volatile ? [.volatileResults] : [],
                                         attributeOptions: [.audioTimeRange])
            return (t, .dictation)
        }
        return nil
    }

    /// Prepares the analyzer while recording is already running. Returns false (the recording
    /// continues without live text; "Transcribe" is offered afterwards) if the model isn't
    /// installed yet or the locale is unsupported.
    func prepare(inputFormat: AVAudioFormat) async -> Bool {
        guard let (module, engine) = await Self.makeModule(locale: locale, volatile: true) else { abandon(); return false }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            // Kick off the one-time download so the next recording has live text.
            Task.detached { try? await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall() }
            abandon()
            return false
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat),
              let converter = AVAudioConverter(from: inputFormat, to: format) else { abandon(); return false }
        converter.primeMethod = .none
        self.module = module
        transcript.engine = engine.rawValue

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        startResults(module: module)
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            abandon()
            return false
        }
        // Drain what the tap queued during setup, in order, then go live. Conversion happens
        // outside the lock in batches so the audio thread is never blocked for long.
        while true {
            enum Step { case batch([AVAudioPCMBuffer]), live, closed }
            let step = withFeed { f -> Step in
                if f.closed { return .closed }
                if f.pending.isEmpty {
                    f.converter = converter
                    f.format = format
                    f.builder = builder
                    f.ready = true
                    return .live
                }
                let batch = f.pending
                f.pending = []
                f.pendingFrames = 0
                return .batch(batch)
            }
            switch step {
            case .batch(let buffers):
                for b in buffers { Self.convertAndYield(b, converter: converter, format: format, builder: builder) }
            case .live:
                return true
            case .closed:
                builder.finish()
                return false
            }
        }
    }

    /// Stops queuing: live transcription won't happen for this recording.
    func abandon() {
        withFeed { f in
            f.closed = true
            f.pending = []
            f.builder?.finish()
            f.builder = nil
        }
    }

    private func startResults(module: any SpeechModule) {
        resultsTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results { self?.handle(text: r.text, range: r.range, isFinal: r.isFinal) }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results { self?.handle(text: r.text, range: r.range, isFinal: r.isFinal) }
                }
            } catch {
                // Transcription failure never affects the recording itself.
            }
        }
    }

    private func handle(text: AttributedString, range: CMTimeRange, isFinal: Bool) {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            onVolatile("")
            guard !plain.isEmpty else { return }
            let seg = Self.segment(text: text, range: range)
            transcript.segments.append(seg)
            TranscriptStore.save(transcript, noteID: noteID)
            onFinal(seg)
        } else if Date().timeIntervalSince(lastVolatileSent) > 0.05 {
            // Throttled: dropping volatile updates is fine; dropping audio never is (PRD §11).
            lastVolatileSent = Date()
            onVolatile(plain)
        }
    }

    static func segment(text: AttributedString, range: CMTimeRange) -> Transcript.Segment {
        var words: [Transcript.Word] = []
        for run in text.runs {
            guard let r = run.audioTimeRange else { continue }
            let w = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { continue }
            words.append(.init(start: r.start.seconds.rounded2, end: r.end.seconds.rounded2, text: w))
        }
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = range.start.seconds.isFinite ? range.start.seconds : (words.first?.start ?? 0)
        let end = range.end.seconds.isFinite ? range.end.seconds : (words.last?.end ?? start)
        return .init(start: start.rounded2, end: end.rounded2, text: plain, words: words)
    }

    // MARK: - Feeding (audio tap thread)

    private func withFeed<R>(_ body: (inout Feed) -> R) -> R {
        feedLock.lock()
        defer { feedLock.unlock() }
        return body(&feedState)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        withFeed { f in
            guard !f.closed else { return }
            if f.ready, let converter = f.converter, let format = f.format, let builder = f.builder {
                Self.convertAndYield(buffer, converter: converter, format: format, builder: builder)
            } else if f.pendingFrames < Self.maxPendingFrames, let copy = buffer.copy() {
                f.pending.append(copy)
                f.pendingFrames += AVAudioFramePosition(copy.frameLength)
            }
        }
    }

    private static func convertAndYield(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, format: AVAudioFormat,
                                         builder: AsyncStream<AnalyzerInput>.Continuation) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { builder.yield(AnalyzerInput(buffer: out)) }
    }

    // MARK: - Finish

    /// Flushes the analyzer and returns the final transcript. Gives up after `timeout`
    /// (keeping every final received so far) so Stop can never hang.
    func finish(timeout: Duration = .seconds(15)) async -> Transcript {
        withFeed { f in
            f.closed = true
            f.pending = []
            f.builder?.finish()
            f.builder = nil
        }
        if let analyzer {
            let results = resultsTask
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                    await results?.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finished {
                await analyzer.cancelAndFinishNow()
                resultsTask?.cancel()
            }
        }
        TranscriptStore.save(transcript, noteID: noteID)
        return transcript
    }

    // MARK: - Backfill ("Transcribe" on a saved recording)

    /// Returns the transcript; the caller decides whether to save it (a speaker-labelled
    /// cloud transcript must never be replaced by an on-device one).
    static func transcribeFile(url: URL, noteID: UUID, recordingID: UUID, locale: Locale,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        guard let (module, engine) = await makeModule(locale: locale, volatile: false) else {
            throw TranscriptionError.unsupportedLocale
        }
        if await AssetInventory.status(forModules: [module]) != .installed {
            try await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let totalSeconds = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [module])

        // Subscribe to results before analysis starts, so nothing is missed.
        let collector = Task { () -> [Transcript.Segment] in
            var segments: [Transcript.Segment] = []
            func add(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
                guard isFinal, !String(text.characters).trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let seg = segment(text: text, range: range)
                segments.append(seg)
                if totalSeconds > 0 { progress?(min(1, seg.end / totalSeconds)) }
            }
            if let t = module as? SpeechTranscriber {
                for try await r in t.results { add(r.text, r.range, r.isFinal) }
            } else if let t = module as? DictationTranscriber {
                for try await r in t.results { add(r.text, r.range, r.isFinal) }
            }
            return segments
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let segments = try await collector.value
        withExtendedLifetime(analyzer) {}

        return Transcript(recordingId: recordingID.uuidString, locale: locale.identifier(.bcp47),
                          engine: engine.rawValue, segments: segments)
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    var errorDescription: String? { "Transcription isn't available for this language on this iPad." }
}

extension Double {
    nonisolated var rounded2: Double { (self * 100).rounded() / 100 }
}

extension AVAudioPCMBuffer {
    /// Deep copy (tap buffers may be reused by the engine after the callback returns).
    nonisolated func copy() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }
}

/// Settings → Audio model status (PRD §6.10).
@MainActor @Observable final class TranscriptionModelStatus {
    static let shared = TranscriptionModelStatus()

    enum State: Equatable {
        case checking, unsupported, notInstalled, downloading(Double), installed(engine: String), failed(String)
    }

    var state: State = .checking
    var supportedLocales: [Locale] = []

    func refresh() async {
        let locale = Locale(identifier: AppSettings.shared.transcriptionLocaleID)
        let supported = await SpeechTranscriber.supportedLocales
        supportedLocales = supported.isEmpty ? await DictationTranscriber.supportedLocales : supported
        guard let (module, engine) = await LiveTranscriber.makeModule(locale: locale, volatile: false) else {
            state = .unsupported
            return
        }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: state = .installed(engine: engine == .speech ? "SpeechTranscriber" : "DictationTranscriber (fallback)")
        case .downloading: state = .downloading(0)
        case .supported: state = .notInstalled
        default: state = .unsupported
        }
    }

    func download() async {
        let locale = Locale(identifier: AppSettings.shared.transcriptionLocaleID)
        guard let (module, _) = await LiveTranscriber.makeModule(locale: locale, volatile: false) else { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                state = .downloading(0)
                let progress = request.progress
                let poll = Task { @MainActor in
                    while !Task.isCancelled {
                        self.state = .downloading(progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await request.downloadAndInstall()
                poll.cancel()
            }
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
