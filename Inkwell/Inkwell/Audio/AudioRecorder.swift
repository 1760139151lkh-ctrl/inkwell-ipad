import Foundation
import AVFoundation
import Observation
import SwiftData
import Synchronization
import UIKit

extension Notification.Name {
    /// A recording's compressed .m4a is ready (object: note UUID).
    static let inkwellAudioTranscoded = Notification.Name("inkwellAudioTranscoded")
    /// A recording's final transcript was written (object: note UUID).
    static let inkwellTranscriptFinished = Notification.Name("inkwellTranscriptFinished")
}

/// App-wide recorder (PRD §7.3). One AVAudioEngine input tap feeds three consumers:
/// the crash-safe capture file, the level meter, and the live transcriber.
@MainActor @Observable final class AudioRecorder {
    static let shared = AudioRecorder()

    enum State: Equatable { case idle, starting, recording, finishing }

    private(set) var state: State = .idle
    private(set) var noteID: UUID?
    private(set) var recordingID: UUID?
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels, 0…1, newest last (for the meter).
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    private(set) var liveFinals: [Transcript.Segment] = []
    private(set) var liveVolatile: String = ""
    private(set) var liveTranscriptionActive = false
    var lastError: String?

    var isRecording: Bool { state == .recording || state == .starting }

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var transcriber: LiveTranscriber?
    private var ticker: Task<Void, Never>?
    private var recording: Recording?
    private var context: ModelContext?
    private var observers: [NSObjectProtocol] = []

    /// Called whenever a recording finishes (so the open editor can reload its timeline).
    var onRecordingFinished: ((UUID) -> Void)?

    private init() {}

    // MARK: - Start

    func start(note: Note, context: ModelContext) async {
        guard state == .idle else { return }
        state = .starting
        lastError = nil
        liveFinals = []
        liveVolatile = ""
        levels = Array(repeating: 0, count: levels.count)
        elapsed = 0

        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone › Inkwell."
            state = .idle
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // No voice processing: its echo cancellation would strip the call audio coming out
            // of the Mac speakers (PRD §7.3). Bluetooth is allowed for output, but the room mic
            // is preferred for input so AirPods don't silently become a narrowband mic.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            state = .idle
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            lastError = "No microphone input is available."
            state = .idle
            return
        }

        let order = (note.recordings.map(\.order).max() ?? -1) + 1
        let rec = Recording(note: note, order: order, startedAt: Date())
        context.insert(rec)
        note.recordings.append(rec)
        note.modifiedAt = Date()
        try? context.save()
        self.recording = rec
        self.context = context
        self.noteID = note.id
        self.recordingID = rec.id

        // The transcriber is created now but prepared after the engine starts: it queues
        // buffers from the first sample, so no audio is lost to model setup (PRD §7.6).
        var transcriber: LiveTranscriber?
        if AppSettings.shared.liveTranscription {
            transcriber = LiveTranscriber(
                noteID: note.id, recordingID: rec.id, locale: Locale(identifier: AppSettings.shared.transcriptionLocaleID),
                onFinal: { seg in Task { @MainActor in AudioRecorder.shared.liveFinals.append(seg) } },
                onVolatile: { text in Task { @MainActor in AudioRecorder.shared.liveVolatile = text } })
        }
        self.transcriber = transcriber

        let sink: CaptureSink
        do {
            sink = try CaptureSink(url: NoteFiles.captureURL(noteID: note.id, recordingID: rec.id),
                                   inputFormat: inputFormat, transcriber: transcriber)
        } catch {
            lastError = "Couldn't create the audio file: \(error.localizedDescription)"
            abortStart(rec, context: context)
            return
        }
        let recID = rec.id
        sink.onFirstBuffer = { date in
            Task { @MainActor in
                let r = AudioRecorder.shared
                guard r.recordingID == recID, let rec = r.recording else { return }
                rec.startedAt = date
                try? r.context?.save()   // persist the precise anchor immediately (crash safety)
            }
        }
        sink.install(on: input)
        self.sink = sink
        self.engine = engine

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = sink.close()
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            abortStart(rec, context: context)
            return
        }

        state = .recording
        observeSession(engine: engine)
        startTicker()

        if let transcriber {
            Task { @MainActor in
                let ok = await transcriber.prepare(inputFormat: inputFormat)
                guard AudioRecorder.shared.recordingID == recID else { return }
                AudioRecorder.shared.liveTranscriptionActive = ok
                if ok { rec.transcriptStatus = .live }
            }
        }
    }

    private func abortStart(_ rec: Recording, context: ModelContext) {
        if let noteID { NoteFiles.deleteRecordingFiles(noteID: noteID, recordingID: rec.id) }
        rec.note?.recordings.removeAll { $0.id == rec.id }
        context.delete(rec)
        try? context.save()
        sink = nil
        engine = nil
        transcriber = nil
        recording = nil
        recordingID = nil
        noteID = nil
        state = .idle
    }

    // MARK: - Stop

    /// Saves the recording immediately; the transcript is finalized and the audio compressed
    /// in the background, so Stop never waits on (or hangs behind) the speech model.
    func stop() async {
        guard state == .recording || state == .starting, let sink, let engine else { return }
        state = .finishing
        ticker?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let frames = sink.close()
        let duration = Double(frames) / sink.fileSampleRate

        let rec = recording
        let noteID = self.noteID
        let transcriber = self.transcriber
        rec?.duration = duration
        rec?.note?.modifiedAt = Date()
        elapsed = duration
        try? context?.save()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        self.sink = nil
        self.engine = nil
        self.transcriber = nil
        self.recording = nil
        self.recordingID = nil
        self.noteID = nil
        liveTranscriptionActive = false
        state = .idle

        guard let noteID, let rec else { return }
        AudioMaintenance.transcodeInBackground(noteID: noteID, recordingID: rec.id)
        onRecordingFinished?(noteID)

        if let transcriber {
            let context = self.context
            Task { @MainActor in
                let transcript = await transcriber.finish()
                rec.transcriptText = transcript.fullText
                rec.transcriptStatus = transcript.segments.isEmpty ? .none : .complete
                rec.note?.modifiedAt = Date()
                try? context?.save()
                BackupEngine.shared.noteChanged()
                NotificationCenter.default.post(name: .inkwellTranscriptFinished, object: noteID)
                // On-device speaker detection needs nothing but this recording's own audio and
                // transcript, so it can start here. The cloud engine ignores this and waits for
                // the audio upload (BackupEngine -> SpeakerDetection.metadataSent).
                SpeakerDetection.shared.recordingFinished(noteID: noteID, recordingID: rec.id)
            }
        }
    }

    // MARK: - Meter / elapsed

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let sink = self.sink else { return }
                let snap = sink.snapshot()
                self.elapsed = Double(snap.frames) / sink.fileSampleRate
                self.levels.removeFirst()
                self.levels.append(snap.level)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    // MARK: - Interruptions, route changes, media resets

    private func observeSession(engine: AVAudioEngine) {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // Phone call etc.: close this segment cleanly; don't auto-resume.
            Task { @MainActor in await AudioRecorder.shared.stop() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            // The input format changed under us (route change). Finish the segment cleanly
            // rather than risk writing mismatched audio; the user can record again.
            Task { @MainActor in
                AudioRecorder.shared.lastError = "The audio input changed, so the recording was stopped and saved."
                await AudioRecorder.shared.stop()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                AudioRecorder.shared.lastError = "iPadOS restarted its audio system, so the recording was stopped and saved."
                await AudioRecorder.shared.stop()
            }
        })
    }

    // MARK: - Crash recovery (PRD §7.3)

    /// Finds recordings left with no duration (force-quit / crash mid-recording),
    /// computes their duration from the capture file, and attaches their transcript.
    static func recoverOrphans(context: ModelContext) {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.duration == 0 })
        guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else { return }
        for rec in orphans {
            guard let noteID = rec.note?.id else { context.delete(rec); continue }
            guard let url = NoteFiles.playableAudioURL(noteID: noteID, recordingID: rec.id),
                  let file = try? AVAudioFile(forReading: url), file.length > 0 else {
                NoteFiles.deleteRecordingFiles(noteID: noteID, recordingID: rec.id)
                context.delete(rec)
                continue
            }
            rec.duration = Double(file.length) / file.processingFormat.sampleRate
            if let t = TranscriptStore.load(noteID: noteID, recordingID: rec.id), !t.segments.isEmpty {
                rec.transcriptText = t.fullText
                rec.transcriptStatus = .complete
            } else {
                rec.transcriptStatus = .none
            }
        }
        try? context.save()
    }
}

// MARK: - Capture sink (audio thread)

/// Everything that runs on the input tap thread. Never touches main-actor state.
nonisolated final class CaptureSink: @unchecked Sendable {
    struct Snapshot { var frames: Int64; var level: Float }

    let fileSampleRate: Double
    private let converter: AVAudioConverter?
    private let processingFormat: AVAudioFormat
    private let transcriber: LiveTranscriber?
    private let meter = Mutex(Snapshot(frames: 0, level: 0))
    /// The file handle, behind a lock: a tap callback can still be running when Stop closes the file.
    private let file: Mutex<AVAudioFile?>
    private let sawFirstBuffer = Mutex(false)
    var onFirstBuffer: (@Sendable (Date) -> Void)?

    init(url: URL, inputFormat: AVAudioFormat, transcriber: LiveTranscriber?) throws {
        // Crash-safe capture: 16-bit PCM in CAF is readable even if the app dies mid-write
        // (unlike .m4a, whose index is only written on close). Transcoded to AAC on stop.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        processingFormat = f.processingFormat
        file = Mutex(f)
        fileSampleRate = inputFormat.sampleRate
        converter = (inputFormat.channelCount == 1 && inputFormat.commonFormat == .pcmFormatFloat32
                     && !inputFormat.isInterleaved) ? nil : AVAudioConverter(from: inputFormat, to: f.processingFormat)
        self.transcriber = transcriber
    }

    func install(on input: AVAudioInputNode) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [self] buffer, when in
            self.process(buffer, when: when)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let first = sawFirstBuffer.withLock { seen -> Bool in
            defer { seen = true }
            return !seen
        }
        if first {
            // Wall-clock anchor of the first captured sample (PRD §7.3).
            var anchor = Date()
            if when.isHostTimeValid {
                let bufferHost = AVAudioTime.seconds(forHostTime: when.hostTime)
                let nowHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                anchor = Date().addingTimeInterval(-(nowHost - bufferHost))
            } else {
                anchor = Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
            }
            onFirstBuffer?(anchor)
        }

        // 1. File (mono)
        var mono: AVAudioPCMBuffer = buffer
        if let converter, let out = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: buffer.frameLength) {
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            mono = out
        }
        let wrote = file.withLock { f -> Bool in
            guard let f else { return false }
            try? f.write(from: mono)
            return true
        }
        guard wrote else { return }

        // 2. Level (RMS → 0…1 over a ~55 dB range)
        var level: Float = 0
        if let data = mono.floatChannelData?[0], mono.frameLength > 0 {
            var sum: Float = 0
            let n = Int(mono.frameLength)
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 1e-6))
            level = max(0, min(1, (db + 55) / 55))
        }
        let frames = Int64(mono.frameLength)
        meter.withLock {
            $0.frames += frames
            $0.level = level
        }

        // 3. Transcriber (same buffer; converted or queued inside)
        transcriber?.feed(buffer)
    }

    func snapshot() -> Snapshot { meter.withLock { $0 } }

    /// Closes the file; returns frames written. Safe against a concurrently running tap callback.
    func close() -> Int64 {
        file.withLock { f in
            f?.close()
            f = nil
        }
        return meter.withLock { $0.frames }
    }
}

// MARK: - Transcoding & audio file maintenance

@MainActor
enum AudioMaintenance {
    /// Compresses a finished capture to .m4a off the main thread, protected by a background task.
    static func transcodeInBackground(noteID: UUID, recordingID: UUID) {
        let bitRate = AppSettings.shared.recordingQuality.bitRate
        let task = UIApplication.shared.beginBackgroundTask(withName: "Compress recording")
        Task.detached(priority: .utility) {
            let ok = AudioTranscoder.transcodeCapture(noteID: noteID, recordingID: recordingID, bitRate: bitRate)
            await MainActor.run {
                if ok { NotificationCenter.default.post(name: .inkwellAudioTranscoded, object: noteID) }
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// Launch-time sweep: retries any capture that never got compressed, and removes capture
    /// files that already have a verified .m4a (safe at launch: nothing is playing them yet)
    /// plus leftover temp files.
    static func sweep(context: ModelContext) {
        let recordings = (try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.duration > 0 }))) ?? []
        let fm = FileManager.default
        for rec in recordings {
            guard let noteID = rec.note?.id else { continue }
            let caf = NoteFiles.captureURL(noteID: noteID, recordingID: rec.id)
            let m4a = NoteFiles.audioURL(noteID: noteID, recordingID: rec.id)
            let tmp = m4a.deletingPathExtension().appendingPathExtension("tmp.m4a")
            try? fm.removeItem(at: tmp)
            guard fm.fileExists(atPath: caf.path) else { continue }
            if fm.fileExists(atPath: m4a.path), AudioTranscoder.isComplete(m4a, expectedDuration: rec.duration) {
                try? fm.removeItem(at: caf)
            } else {
                try? fm.removeItem(at: m4a)
                transcodeInBackground(noteID: noteID, recordingID: rec.id)
            }
        }
    }
}

nonisolated enum AudioTranscoder {
    /// CAF (PCM) → M4A (AAC mono), written to a temp file and moved into place. The CAF is
    /// kept (an open player may still be reading it) and removed by the next launch sweep.
    @discardableResult
    static func transcodeCapture(noteID: UUID, recordingID: UUID, bitRate: Int) -> Bool {
        let src = NoteFiles.captureURL(noteID: noteID, recordingID: recordingID)
        let dst = NoteFiles.audioURL(noteID: noteID, recordingID: recordingID)
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        let tmp = dst.deletingPathExtension().appendingPathExtension("tmp.m4a")
        do {
            let input = try AVAudioFile(forReading: src)
            let rate = input.processingFormat.sampleRate
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
            try? FileManager.default.removeItem(at: tmp)
            var output: AVAudioFile? = try AVAudioFile(forWriting: tmp, settings: settings,
                                                       commonFormat: input.processingFormat.commonFormat,
                                                       interleaved: input.processingFormat.isInterleaved)
            let chunk: AVAudioFrameCount = 32_768
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else { return false }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output?.write(from: buffer)
            }
            output?.close()
            output = nil
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false   // the CAF stays; it is still playable and the launch sweep retries
        }
    }

    /// True if the .m4a opens and is (nearly) as long as the recording.
    static func isComplete(_ url: URL, expectedDuration: Double) -> Bool {
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        let seconds = Double(f.length) / f.processingFormat.sampleRate
        return seconds >= expectedDuration - 0.5
    }
}
