import Foundation
import Observation
import SwiftData
import SwiftUI

/// Speaker detection (diarization) — the one thing the UI talks to, whichever engine is doing
/// the work. Apple ships no diarization API, so the labels come from one of two places:
///
///  * **On this iPad** (`SpeakerEngine.onDevice`, the default): `LocalDiarizer` embeds the
///    recording's own audio with a bundled Core ML voiceprint model and clusters it. No upload,
///    no bill. That half lives in `Audio/Diarization/SpeakerDetection+Local.swift`.
///  * **Cloud** (`SpeakerEngine.cloud`): once a recording's audio is in the backup bucket the
///    server re-transcribes it with a diarizing model and the labelled transcript replaces the
///    local one. That is everything below, unchanged, and stays the fallback.
@MainActor @Observable final class SpeakerDetection {
    static let shared = SpeakerDetection()

    enum Status: Equatable {
        case waitingForUpload
        case running
        case done
        case failed(String)
    }

    /// Per recording (only recordings that have been requested this session).
    private(set) var status: [UUID: Status] = [:]
    var pollers: [UUID: Task<Void, Never>] = [:]
    var context: ModelContext?

    private init() {}

    func attach(context: ModelContext) { self.context = context }

    /// Account switch: stop polling and forget the old store.
    func detach() {
        for task in pollers.values { task.cancel() }
        pollers = [:]
        status = [:]
        awaitingUpload = []
        context = nil
    }

    /// Can speaker detection run at all right now, for the engine that's selected?
    var isAvailable: Bool {
        switch AppSettings.shared.speakerEngine {
        case .onDevice: SpeakerEmbedder.isBundled
        case .cloud: BackupEngine.shared.isConfigured
        }
    }

    /// Lets the on-device half report progress through the same `status` the UI already reads.
    func setStatus(_ s: Status?, for recordingID: UUID) { status[recordingID] = s }

    /// Recordings whose diarize call hit 409 (audio not registered yet); retried after the next backup.
    private var awaitingUpload: Set<UUID> = []
    /// Recordings already auto-requested once (persisted, so failures aren't re-billed every launch).
    private var autoRequested: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "speakers.autoRequested") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(2000)), forKey: "speakers.autoRequested") }
    }

    /// Called by the backup engine after a note's metadata PUT succeeded, with the recordings
    /// whose audio the server now knows about. This is the only safe moment to diarize.
    func metadataSent(noteID: UUID, recordingIDs: [UUID]) {
        for rid in recordingIDs {
            if awaitingUpload.remove(rid) != nil {
                start(noteID: noteID, recordingID: rid)
                continue
            }
            guard AppSettings.shared.detectSpeakers, pollers[rid] == nil, status[rid] == nil,
                  !autoRequested.contains(rid.lowercased) else { continue }
            if let t = TranscriptStore.load(noteID: noteID, recordingID: rid), !t.speakers.isEmpty { continue }
            autoRequested.insert(rid.lowercased)
            start(noteID: noteID, recordingID: rid)
        }
    }

    /// Starts (or resumes polling) detection for one recording, on whichever engine is selected.
    func start(noteID: UUID, recordingID: UUID) {
        if AppSettings.shared.speakerEngine == .onDevice {
            startOnDevice(noteID: noteID, recordingID: recordingID)
            return
        }
        NSLog("[SPK] start rec=%@ note=%@ polling=%@ apiConfigured=%@",
              recordingID.uuidString, noteID.uuidString,
              pollers[recordingID] == nil ? "no" : "YES-ALREADY-RUNNING",
              BackupEngine.shared.api == nil ? "NO-API" : "yes")
        guard pollers[recordingID] == nil else { NSLog("[SPK] ABORT: a poller is already running for this recording"); return }
        guard let api = BackupEngine.shared.api else { NSLog("[SPK] ABORT: BackupEngine.api is nil (no https backupURL or no keychain token)"); return }
        status[recordingID] = .running
        pollers[recordingID] = Task { [weak self] in
            await self?.run(api: api, noteID: noteID, recordingID: recordingID)
            self?.pollers[recordingID] = nil
        }
    }

    private func run(api: BackupAPI, noteID: UUID, recordingID: UUID) async {
        let rid = recordingID.lowercased
        do {
            NSLog("[SPK] POST api/recordings/%@/diarize", rid)
            var json = try await api.call("POST", "api/recordings/\(rid)/diarize")
            NSLog("[SPK] diarize returned status=%@ keys=%@", (json["status"] as? String) ?? "nil", json.keys.joined(separator: ","))
            let deadline = Date().addingTimeInterval(45 * 60)
            while Date() < deadline {
                switch json["status"] as? String {
                case "done":
                    NSLog("[SPK] done")
                    try apply(json, noteID: noteID, recordingID: recordingID)
                    status[recordingID] = .done
                    return
                case "failed":
                    NSLog("[SPK] server reported failed: %@", (json["error"] as? String) ?? "no error text")
                    status[recordingID] = .failed((json["error"] as? String) ?? "Speaker detection failed.")
                    return
                default:
                    NSLog("[SPK] polling… status=%@", (json["status"] as? String) ?? "nil")
                    try await Task.sleep(for: .seconds(5))
                    json = try await api.call("GET", "api/recordings/\(rid)/diarization")
                }
            }
            status[recordingID] = .failed("Speaker detection is taking too long; try again later.")
        } catch let e as BackupAPI.APIError where e.status == 409 {
            NSLog("[SPK] 409 — audio not registered in the backup bucket yet; waiting for upload")
            // Audio isn't registered yet; the next successful backup of this note restarts us.
            status[recordingID] = .waitingForUpload
            awaitingUpload.insert(recordingID)
            BackupEngine.shared.noteChanged()
        } catch is CancellationError {
            status[recordingID] = nil
        } catch {
            NSLog("[SPK] ERROR: %@", String(describing: error))
            status[recordingID] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Writes the diarized transcript as the recording's local sidecar and refreshes the note.
    private func apply(_ json: [String: Any], noteID: UUID, recordingID: UUID) throws {
        let tAny = json["transcript"]
        NSLog("[SPK] apply: transcript type=%@", String(describing: type(of: tAny)))
        guard let t = json["transcript"] as? [String: Any] else {
            NSLog("[SPK] apply ABORT: transcript is not a dictionary")
            return
        }
        NSLog("[SPK] apply: transcript keys=%@", t.keys.joined(separator: ","))
        guard let segs = t["segments"] else {
            NSLog("[SPK] apply ABORT: no 'segments' key inside transcript")
            return
        }
        NSLog("[SPK] apply: segments type=%@ count=%d", String(describing: type(of: segs)), (segs as? [Any])?.count ?? -1)
        if let arr = segs as? [[String: Any]], let f = arr.first {
            NSLog("[SPK] apply: first segment keys=%@", f.keys.joined(separator: ","))
        }
        let data = try JSONSerialization.data(withJSONObject: segs)
        let segments: [Transcript.Segment]
        do {
            segments = try JSONDecoder().decode([Transcript.Segment].self, from: data)
            NSLog("[SPK] apply: decoded %d segments", segments.count)
        } catch {
            NSLog("[SPK] apply DECODE FAILED: %@", String(describing: error))
            throw error
        }
        guard !segments.isEmpty else { NSLog("[SPK] apply ABORT: zero segments"); return }
        NSLog("[SPK] apply: speaker values=%@", segments.map { $0.speaker ?? "nil" }.joined(separator: "|"))
        NSLog("[SPK] apply: audio_duration_s=%@ provider=%@",
              String(describing: json["audio_duration_s"] ?? "?"), String(describing: json["provider"] ?? "?"))
        let transcript = Transcript(recordingId: recordingID.uuidString,
                                    locale: t["locale"] as? String ?? AppSettings.shared.transcriptionLocaleID,
                                    engine: t["engine"] as? String ?? "cloud", segments: segments)
        TranscriptStore.save(transcript, noteID: noteID)
        if let context, let rec = try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })).first {
            rec.transcriptText = transcript.fullText
            rec.transcriptStatus = .complete
            try? context.save()
        }
        NSLog("[SPK] apply: computed speakers=%@ (count=%d) — saved + notified",
              transcript.speakers.joined(separator: ","), transcript.speakers.count)
        NotificationCenter.default.post(name: .inkwellTranscriptFinished, object: noteID)
    }
}

/// Names Pat has given speakers before, most recent first — offered as suggestions.
enum SpeakerDirectory {
    private static let key = "speakers.knownNames"

    static var names: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func remember(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var list = names.filter { $0.caseInsensitiveCompare(n) != .orderedSame }
        list.insert(n, at: 0)
        UserDefaults.standard.set(Array(list.prefix(40)), forKey: key)
    }

    /// Stable color per label.
    static func color(for label: String) -> Color {
        let palette = ["#4A90E2", "#E6A23C", "#5BBF8A", "#B07CE0", "#E05A7A", "#4FB3A9", "#D9C84A", "#8E9BB0"]
        let n = Int(label.drop(while: { !$0.isNumber })) ?? 1
        return Color(hex: palette[(max(n, 1) - 1) % palette.count])
    }
}
