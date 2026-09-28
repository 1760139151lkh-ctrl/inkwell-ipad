import XCTest
import SwiftData
@testable import Inkwell

/// Phase 4: moving signed-out notes into an account, and token bookkeeping.
@MainActor final class AccountTests: XCTestCase {
    private var source: StorageScope!
    private var dest: StorageScope!

    override func setUp() async throws {
        source = .account("test-src-\(UUID().uuidString.lowercased())")
        dest = .account("test-dst-\(UUID().uuidString.lowercased())")
    }

    override func tearDown() async throws {
        for s in [source, dest].compactMap({ $0 }) { try? FileManager.default.removeItem(at: s.directory) }
    }

    private func seed(_ scope: StorageScope) throws -> (note: Note, subject: Subject) {
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
        let ctx = ModelContext(try AppSession.openContainer(scope))
        let subject = Subject(name: "Client Work", colorHex: "#4A90E2", sortIndex: 0)
        ctx.insert(subject)
        let note = Note(title: "Kickoff", subject: subject, paper: Paper())
        ctx.insert(note)
        let rec = Recording(note: note, order: 0, startedAt: Date(timeIntervalSince1970: 1000))
        rec.duration = 42
        ctx.insert(rec)
        note.speakerNames = ["S1": "Priya"]
        try ctx.save()
        // A file in the note's folder.
        let folder = scope.notesRoot.appendingPathComponent(note.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("ink".utf8).write(to: folder.appendingPathComponent("drawing.pkdrawing"))
        return (note, subject)
    }

    func testAdoptMovesNotesFilesAndEmptiesSource() throws {
        let (note, subject) = try seed(source)
        let result = try StoreMerger.adopt(from: source, into: dest, keepManifest: false)
        XCTAssertEqual(result.notes, 1)
        XCTAssertEqual(result.subjects, 1)

        let dst = ModelContext(try AppSession.openContainer(dest))
        let moved = try dst.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(moved.map(\.id), [note.id], "ids are preserved so a claimed backup still matches")
        XCTAssertEqual(moved.first?.subject?.id, subject.id)
        XCTAssertEqual(moved.first?.recordings.first?.duration, 42)
        XCTAssertEqual(moved.first?.speakerNames["S1"], "Priya")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.notesRoot
            .appendingPathComponent(note.id.uuidString).appendingPathComponent("drawing.pkdrawing").path))

        let src = ModelContext(try AppSession.openContainer(source))
        XCTAssertEqual(try src.fetchCount(FetchDescriptor<Note>()), 0)
        XCTAssertEqual(try src.fetchCount(FetchDescriptor<Subject>()), 0)
    }

    func testAdoptIsIdempotentAfterInterruption() throws {
        let (note, _) = try seed(source)
        _ = try StoreMerger.adopt(from: source, into: dest, keepManifest: false)
        // Re-running (e.g. after a crash mid-way) must not duplicate anything.
        let again = try StoreMerger.adopt(from: source, into: dest, keepManifest: false)
        XCTAssertEqual(again.notes, 0)
        let dst = ModelContext(try AppSession.openContainer(dest))
        XCTAssertEqual(try dst.fetch(FetchDescriptor<Note>()).map(\.id), [note.id])
    }

    func testManifestCarriesOverOnlyWhenBackupWasClaimed() throws {
        let (note, _) = try seed(source)
        var m = BackupManifest()
        m.notes[note.id.uuidString.lowercased()] = .init()
        try JSONEncoder().encode(m).write(to: source.manifestURL)
        _ = try StoreMerger.adopt(from: source, into: dest, keepManifest: true)
        let merged = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: dest.manifestURL))
        XCTAssertNotNil(merged.notes[note.id.uuidString.lowercased()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.manifestURL.path))
    }

    func testJWTExpiryParsing() {
        // {"alg":"EdDSA"}.{"sub":"u","exp":2000000000}.sig
        let jwt = "eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJ1IiwiZXhwIjoyMDAwMDAwMDAwfQ.c2ln"
        XCTAssertEqual(AuthClient.expiry(of: jwt), Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(AuthClient.expiry(of: "not-a-jwt"))
    }

    func testAuthErrorMapping() {
        XCTAssertEqual(AuthClient.mapError(status: 400, json: ["code": "INVALID_OTP"]), .invalidCode)
        XCTAssertEqual(AuthClient.mapError(status: 400, json: ["code": "OTP_EXPIRED"]), .codeExpired)
        XCTAssertEqual(AuthClient.mapError(status: 429, json: [:]), .tooManyAttempts)
    }
}
