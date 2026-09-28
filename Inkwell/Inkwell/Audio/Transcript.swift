import Foundation

/// `transcript/<recordingID>.json` (PRD §7.6). Only final results are persisted.
nonisolated struct Transcript: Codable, Equatable {
    struct Word: Codable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    struct Segment: Codable, Equatable, Identifiable {
        var start: Double
        var end: Double
        var text: String
        var words: [Word]
        /// Speaker label from cloud diarization ("S1", "S2", …); nil for on-device transcripts.
        var speaker: String?
        var id: Double { start }
    }

    /// Distinct speaker labels in order of first appearance.
    var speakers: [String] {
        var seen: [String] = []
        for s in segments { if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) } }
        return seen
    }

    var recordingId: String
    var locale: String
    var engine: String
    var segments: [Segment]

    var fullText: String { segments.map(\.text).joined(separator: " ") }
}

nonisolated enum TranscriptStore {
    static func load(noteID: UUID, recordingID: UUID) -> Transcript? {
        let url = NoteFiles.transcriptURL(noteID: noteID, recordingID: recordingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    static func save(_ transcript: Transcript, noteID: UUID) {
        guard let id = UUID(uuidString: transcript.recordingId) else { return }
        let url = NoteFiles.transcriptURL(noteID: noteID, recordingID: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(transcript) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
