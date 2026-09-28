import Foundation
import AVFoundation
import Observation

/// Plays all of a note's recordings as one continuous timeline (PRD §7.4):
/// one AVMutableComposition, one AVPlayer, a ~30 Hz time observer.
@MainActor @Observable final class PlaybackController {
    private(set) var timeline = NoteTimeline(segments: [])
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    /// Replay mode: on once the playhead has been started or scrubbed (PRD §7.4).
    private(set) var isEngaged = false
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// Recording id → "duration|file", so a finished .m4a transcode triggers a rebuild.
    private var loadedKey: [UUID: String] = [:]
    /// Guards against two overlapping loads (each awaits asset loading).
    private var loadGeneration = 0
    private(set) var loadError: String?
    /// A seek is in flight: ignore the time observer until it lands, or the playhead (and the
    /// highlighted transcript line) snaps back to the old position for a moment.
    private var seekGeneration = 0
    private var seeking = false
    /// Play was requested while the composition was being (re)built; start once it's ready.
    private var pendingPlay = false

    /// Fires on every tick with the timeline time.
    var onTick: ((TimeInterval) -> Void)?

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var duration: TimeInterval { timeline.totalDuration }
    var hasAudio: Bool { duration > 0 }

    /// Rebuilds the composition if the note's recordings changed.
    func load(noteID: UUID, recordings: [Recording]) async {
        let items = recordings.filter { $0.duration > 0 }.sorted { $0.order < $1.order }
        let key = Dictionary(uniqueKeysWithValues: items.map { rec in
            (rec.id, "\(rec.duration)|\(NoteFiles.playableAudioURL(noteID: noteID, recordingID: rec.id)?.lastPathComponent ?? "-")")
        })
        guard key != loadedKey || (player == nil && !items.isEmpty) else { return }
        // Don't swap the player out from under active playback; the next load will pick it up.
        if isPlaying && key.keys == loadedKey.keys && Set(items.map(\.id)) == Set(loadedKey.keys)
            && items.allSatisfy({ loadedKey[$0.id]?.hasPrefix("\($0.duration)|") == true }) { return }
        loadedKey = key
        loadGeneration += 1
        let generation = loadGeneration
        loadError = nil

        let wasTime = currentTime
        teardownPlayer()
        timeline = NoteTimeline(items.map { ($0.id, $0.startedAt, $0.duration) })
        guard !items.isEmpty else { return }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        var cursor = CMTime.zero
        for rec in items {
            guard let url = NoteFiles.playableAudioURL(noteID: noteID, recordingID: rec.id) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            guard generation == loadGeneration else { return }
            // Use the recording's own duration so the audio and the stroke timeline agree exactly.
            let length = CMTime(seconds: rec.duration, preferredTimescale: 48_000)
            let assetDuration = (try? await asset.load(.duration)) ?? length
            let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(length, assetDuration))
            try? track.insertTimeRange(range, of: source, at: cursor)
            cursor = CMTimeAdd(cursor, length)
        }

        guard generation == loadGeneration else { return }
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.seeking else { return }
                self.currentTime = min(time.seconds, self.duration)
                self.onTick?(self.currentTime)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
                self.onTick?(self.currentTime)
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.loadError = "This recording couldn't be played."
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                      object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        // Resume where the user is *now*: a line tap during the rebuild moved currentTime.
        let resumeAt = currentTime > 0 ? currentTime : wasTime
        if resumeAt > 0 { seek(to: min(resumeAt, duration), engage: false) }
        if pendingPlay {
            pendingPlay = false
            play()
        }
    }

    func play() {
        guard hasAudio else { return }
        guard let player else {
            pendingPlay = true   // composition is rebuilding (e.g. the .m4a just landed)
            return
        }
        guard !AudioRecorder.shared.isRecording else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if currentTime >= duration - 0.05 { seek(to: 0, engage: true) }
        isEngaged = true
        player.playImmediately(atRate: rate)
        isPlaying = true
        onTick?(currentTime)
    }

    func pause() {
        pendingPlay = false
        player?.pause()
        isPlaying = false
        onTick?(currentTime)
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to t: TimeInterval, engage: Bool = true) {
        let t = max(0, min(duration, t))
        currentTime = t
        if engage { isEngaged = true }
        if let player {
            seekGeneration += 1
            let generation = seekGeneration
            seeking = true
            player.seek(to: CMTime(seconds: t, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.seekGeneration else { return }
                    self.seeking = false
                }
            }
        }
        onTick?(t)
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    /// Seek + always play (tap on ink: 1 s pre-roll so you hear the lead-in; transcript line: none).
    func jump(to t: TimeInterval, preRoll: TimeInterval = 1) {
        seek(to: max(0, t - preRoll))
        play()
    }

    /// Leaves replay mode: ink returns to full opacity.
    func disengage() {
        pause()
        isEngaged = false
        onTick?(currentTime)
    }

    func teardown() {
        teardownPlayer()
        isEngaged = false
    }

    private func teardownPlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        statusObservation?.invalidate()
        statusObservation = nil
        // A seek on the old player may never complete; don't leave the time observer muted.
        seeking = false
        seekGeneration += 1
        timeObserver = nil
        endObserver = nil
        interruptionObserver = nil
        player = nil
        isPlaying = false
    }
}
