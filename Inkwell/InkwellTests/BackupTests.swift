import XCTest
import SwiftData
@testable import Inkwell

/// Backup key layout (server/README.md): server paths use lowercase UUIDs; local files use
/// `UUID.uuidString` (uppercase). Restore must map one to the other exactly.
@MainActor final class BackupTests: XCTestCase {
    private func makeNote() throws -> (ModelContainer, Note) {
        let schema = Schema([Subject.self, SubjectDivider.self, Note.self, Recording.self, PageElement.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let note = Note(title: "t", subject: nil, paper: Paper())
        container.mainContext.insert(note)
        return (container, note)
    }

    func testServerPathsMapBackToLocalFiles() throws {
        let (container, note) = try makeNote()
        defer { withExtendedLifetime(container) {} }
        let rec = UUID()
        XCTAssertEqual(BackupPayload.localURL(forPath: "audio/\(rec.lowercased).m4a", note: note),
                       NoteFiles.audioURL(noteID: note.id, recordingID: rec))
        XCTAssertEqual(BackupPayload.localURL(forPath: "transcript/\(rec.lowercased).json", note: note),
                       NoteFiles.transcriptURL(noteID: note.id, recordingID: rec))
        XCTAssertEqual(BackupPayload.localURL(forPath: "drawing.pkdrawing", note: note), NoteFiles.drawingURL(note.id))
        XCTAssertEqual(BackupPayload.localURL(forPath: "images/\(rec.lowercased).jpg", note: note)?.lastPathComponent,
                       "\(rec.uuidString).jpg")
        XCTAssertNil(BackupPayload.localURL(forPath: "../etc/passwd", note: note))
        XCTAssertNil(BackupPayload.localURL(forPath: "audio/not-a-uuid.m4a", note: note))
    }

    func testFileListUsesLowercaseServerPaths() throws {
        let (container, note) = try makeNote()
        let rec = Recording(note: note, order: 0, startedAt: Date())
        rec.duration = 3
        container.mainContext.insert(rec)
        note.recordings.append(rec)
        let url = NoteFiles.audioURL(noteID: note.id, recordingID: rec.id)
        try Data([1, 2, 3]).write(to: url)
        defer {
            NoteFiles.deleteNoteFolder(note.id)
            withExtendedLifetime(container) {}
        }
        let files = BackupFiles.list(for: note)
        XCTAssertTrue(files.contains { $0.path == "audio/\(rec.id.uuidString.lowercased()).m4a" && $0.isAudio })
        XCTAssertTrue(files.allSatisfy { $0.path == $0.path.lowercased() || $0.path.hasSuffix(".pkdrawing") })
    }

    func testSHA256MatchesKnownVector() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(BackupAPI.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTextBoxHeightGrowsWithText() {
        let font = UIFont.systemFont(ofSize: 16)
        let one = ElementSnapshot.textHeight("hello", width: 200, font: font)
        let many = ElementSnapshot.textHeight(String(repeating: "hello world ", count: 20), width: 200, font: font)
        XCTAssertGreaterThan(many, one * 3)
    }
}

/// Speaker labels are optional so transcripts written before speaker detection still decode.
final class SpeakerTranscriptTests: XCTestCase {
    func testOldTranscriptWithoutSpeakersDecodes() throws {
        let json = #"{"recordingId":"x","locale":"en-US","engine":"SpeechTranscriber","segments":[{"start":0,"end":1,"text":"hi","words":[]}]}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertNil(t.segments[0].speaker)
        XCTAssertTrue(t.speakers.isEmpty)
    }

    func testSpeakersInOrderOfFirstAppearance() throws {
        let json = #"{"recordingId":"x","locale":"en-US","engine":"cloud","segments":[{"start":0,"end":1,"text":"a","words":[],"speaker":"S2"},{"start":1,"end":2,"text":"b","words":[],"speaker":"S1"},{"start":2,"end":3,"text":"c","words":[],"speaker":"S2"}]}"#
        let t = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertEqual(t.speakers, ["S2", "S1"])
        let round = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(round.segments.map(\.speaker), ["S2", "S1", "S2"])
    }
}
