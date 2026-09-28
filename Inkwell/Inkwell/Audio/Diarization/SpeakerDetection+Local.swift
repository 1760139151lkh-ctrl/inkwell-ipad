import Foundation
import SwiftData

/// The on-device half of `SpeakerDetection`: runs `LocalDiarizer` on a recording's own audio
/// and writes the "S1"/"S2"/… labels into its transcript sidecar. Reports through the same
/// `status` dictionary the cloud path uses, so the transcript UI needs no changes.
extension SpeakerDetection {
    /// Recordings already diarized on-device once, so a failure isn't retried every launch.
    private static let autoKey = "speakers.autoRequestedLocal"

    func startOnDevice(noteID: UUID, recordingID: UUID) {
        guard pollers[recordingID] == nil else {
            NSLog("[SPK] local: already running for %@", recordingID.uuidString); return
        }
        guard SpeakerEmbedder.isBundled else {
            NSLog("[SPK] local ABORT: SpeakerEmbedding.mlmodelc is not in the bundle")
            setStatus(.failed(SpeakerEmbedder.Failure.modelMissing.localizedDescription), for: recordingID)
            return
        }
        guard let url = NoteFiles.playableAudioURL(noteID: noteID, recordingID: recordingID) else {
            NSLog("[SPK] local ABORT: no audio file for %@", recordingID.uuidString)
            setStatus(.failed(LocalDiarizer.Failure.noAudio.localizedDescription), for: recordingID)
            return
        }
        guard let transcript = TranscriptStore.load(noteID: noteID, recordingID: recordingID),
              !transcript.segments.isEmpty else {
            NSLog("[SPK] local ABORT: no transcript to label yet for %@", recordingID.uuidString)
            setStatus(.failed("Transcribe this recording first, then find speakers."), for: recordingID)
            return
        }

        setStatus(.running, for: recordingID)
        pollers[recordingID] = Task { [weak self] in
            let outcome: Result<LocalDiarizer.Result, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try LocalDiarizer.diarize(audioURL: url, segments: transcript.segments)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let result):
                NSLog("[SPK] local done in %.2fs — audio %.1fs, speech %.1fs, %d windows, %d speakers: %@",
                      result.elapsedSeconds, result.audioSeconds, result.speechSeconds,
                      result.windows, result.speakerCount,
                      result.labels.map { $0 ?? "-" }.joined(separator: "|"))
                self.applyLocal(result, to: transcript, noteID: noteID, recordingID: recordingID)
                self.setStatus(.done, for: recordingID)
            case .failure(let error):
                NSLog("[SPK] local FAILED: %@", String(describing: error))
                self.setStatus(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription),
                               for: recordingID)
            }
            self.pollers[recordingID] = nil
        }
    }

    /// Auto-trigger for the on-device engine. The cloud path has to wait for an upload
    /// (`metadataSent`); this one only needs the recording's own audio and transcript, so it
    /// runs as soon as the recording is finished.
    func recordingFinished(noteID: UUID, recordingID: UUID) {
        guard AppSettings.shared.speakerEngine == .onDevice, AppSettings.shared.detectSpeakers else { return }
        guard pollers[recordingID] == nil, status[recordingID] == nil else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.autoKey) ?? [])
        guard !done.contains(recordingID.lowercased) else { return }
        if let t = TranscriptStore.load(noteID: noteID, recordingID: recordingID), !t.speakers.isEmpty { return }
        done.insert(recordingID.lowercased)
        UserDefaults.standard.set(Array(done.suffix(2000)), forKey: Self.autoKey)
        startOnDevice(noteID: noteID, recordingID: recordingID)
    }

    /// Writes the labels onto the existing transcript. Only `speaker` changes — the text, the
    /// timings and the word timings all stay exactly as the on-device transcriber produced them.
    private func applyLocal(_ result: LocalDiarizer.Result, to transcript: Transcript,
                            noteID: UUID, recordingID: UUID) {
        guard result.labels.count == transcript.segments.count else {
            NSLog("[SPK] local apply ABORT: %d labels for %d segments",
                  result.labels.count, transcript.segments.count)
            return
        }
        var labelled = transcript
        labelled.engine = transcript.engine.isEmpty ? "on-device" : transcript.engine
        for i in labelled.segments.indices { labelled.segments[i].speaker = result.labels[i] }
        TranscriptStore.save(labelled, noteID: noteID)
        if let context,
           let rec = try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })).first {
            rec.transcriptStatus = .complete
            rec.note?.modifiedAt = Date()
            try? context.save()
        }
        NSLog("[SPK] local apply: speakers=%@", labelled.speakers.joined(separator: ","))
        NotificationCenter.default.post(name: .inkwellTranscriptFinished, object: noteID)
        BackupEngine.shared.noteChanged()
    }
}
