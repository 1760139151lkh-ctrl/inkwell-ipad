import Foundation
import Observation
import PencilKit
import SwiftData
import UIKit

/// One-way cloud backup to Neon (PRD §8.3). The iPad is the source of truth; the server
/// holds a copy. Order per note (server/README.md): hash files → upload changed files →
/// PUT metadata → mark backed up. Never blocks writing or recording.
@MainActor @Observable final class BackupEngine {
    static let shared = BackupEngine()

    enum Phase: Equatable {
        case idle
        case backingUp(done: Int, total: Int)
        case restoring(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastBackupAt: Date? {
        didSet { UserDefaults.standard.set(lastBackupAt, forKey: Self.lastAtKey) }
    }
    private static var lastAtKey: String { "backup.lastAt.\(StorageScope.current.id)" }
    private(set) var lastRestoreSummary: String?

    private var context: ModelContext?
    private var debounce: Task<Void, Never>?
    private var running = false
    private var rerunRequested = false
    private var manifest = BackupManifest.load()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundRun: Task<Void, Never>?

    private init() {
        lastBackupAt = UserDefaults.standard.object(forKey: Self.lastAtKey) as? Date
    }

    // MARK: Configuration

    func attach(context: ModelContext) { self.context = context }

    /// Account switch: stop using the old store entirely.
    func detach() {
        debounce?.cancel()
        context = nil
    }

    /// Loads the per-account manifest and status for the scope about to open.
    func reload(for scope: StorageScope) {
        manifest = BackupManifest.load()
        lastBackupAt = UserDefaults.standard.object(forKey: Self.lastAtKey) as? Date
        lastRestoreSummary = nil
        phase = .idle
    }

    private var suspended = false

    /// Backup/restore runs in flight, so an account switch can cancel them.
    private var activeRuns: [UUID: Task<Void, Never>] = [:]

    private func tracked(_ work: @escaping @MainActor () async -> Void) async {
        let id = UUID()
        let task = Task { await work() }
        activeRuns[id] = task
        await task.value
        activeRuns[id] = nil
    }

    /// Blocks new runs, cancels the ones in flight and waits for them to stop.
    func suspend() async {
        suspended = true
        debounce?.cancel()
        let runs = Array(activeRuns.values)
        for run in runs { run.cancel() }
        for run in runs { await run.value }
        for _ in 0..<100 where running { try? await Task.sleep(for: .milliseconds(200)) }   // backUpSingle
    }

    func resume() { suspended = false }

    /// Backups belong to the signed-in account; notes made while signed out stay on the iPad.
    var api: BackupAPI? {
        guard let url = AppConfig.apiURL, let uid = StorageScope.current.accountID, AccountManager.shared.isSignedIn,
              AccountManager.shared.user?.id == uid else { return nil }
        // Bound to this account: a run that outlives a sign-out can't act as the next account.
        return BackupAPI(baseURL: url, token: { refresh in try await AuthClient.shared.accessToken(for: uid, forceRefresh: refresh) })
    }

    /// The pre-accounts shared backup token (Keychain). Only used once, to claim that
    /// backup for the first account signed in on this iPad; then deleted.
    static let legacyTokenKey = "inkwell.api.token"
    var isConfigured: Bool { api != nil }

    var statusLine: String {
        switch phase {
        case .backingUp(let done, let total): return total > 0 ? "Backing up \(done + 1) of \(total) notes…" : "Checking…"
        case .restoring(let s): return s
        case .failed(let msg): return msg
        case .idle:
            guard isConfigured else {
                return AccountManager.shared.needsReauth ? "Paused — sign in again to resume" : "Sign in to back up"
            }
            guard let last = lastBackupAt else { return "Not backed up yet" }
            return "Last backup \(last.formatted(.relative(presentation: .named)))"
        }
    }

    // MARK: Triggers

    /// Called after edits: backs up 30 s after the last change (PRD §8.3).
    func noteChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.backUpNow()
        }
    }

    /// App went to the background: run now, inside a background task that is always ended
    /// (on completion or when iPadOS says time is up — never letting the app get killed).
    func appDidEnterBackground() {
        guard isConfigured, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Inkwell backup") { [weak self] in
            MainActor.assumeIsolated {
                self?.backgroundRun?.cancel()
                self?.endBackgroundTask()
            }
        }
        backgroundRun = Task { [weak self] in
            await self?.backUpNow()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        backgroundRun = nil
    }

    /// Permanently deleted notes still need a server tombstone.
    func notePermanentlyDeleted(_ id: UUID) {
        manifest.pendingDeletes.insert(id.lowercased)
        manifest.save()
        noteChanged()
    }

    /// A background audio upload finished (possibly after a relaunch). Records it and
    /// schedules the metadata PUT that references the new key.
    func backgroundUploadFinished(noteID: String, path: String, sha256: String, key: String, success: Bool) {
        // Started under another account (signed out / switched since): that account's next
        // backup re-checks the file, so don't record it in this one's manifest.
        guard let id = UUID(uuidString: noteID), let context, fetch(id, in: context) != nil else { return }
        manifest.inFlight["\(noteID)|\(path)|\(sha256)"] = nil
        if success {
            manifest.notes[noteID, default: .init()].files[path] = .init(sha256: sha256, key: key)
            manifest.notes[noteID, default: .init()].needsMetadata = true
        }
        manifest.save()
        if success {
            noteChanged()
            // Register the new audio key promptly (speaker detection starts after that PUT).
            Task { await self.backUpNow() }
        } else {
            // Back off rather than re-uploading a large file every debounce interval.
            Task { try? await Task.sleep(for: .seconds(300)); self.noteChanged() }
        }
    }

    // MARK: Backup

    func backUpNow() async {
        guard !suspended else { return }
        await tracked { await self.performBackup() }
    }

    private func performBackup() async {
        guard !suspended, let api, let context else { return }
        guard !running else { rerunRequested = true; return }
        running = true
        defer {
            running = false
            if rerunRequested {
                rerunRequested = false
                Task { await self.backUpNow() }
            }
        }
        phase = .backingUp(done: 0, total: 0)
        do {
            // Server tombstones for permanently deleted notes.
            for id in manifest.pendingDeletes {
                do { _ = try await api.call("DELETE", "api/notes/\(id)") }
                catch let e as BackupAPI.APIError where e.status == 404 {}
                manifest.pendingDeletes.remove(id)
                manifest.notes[id] = nil
                manifest.save()
            }
            try await syncSubjects(api: api, context: context)
        } catch {
            if (error as? BackupAPI.APIError)?.isSessionExpired == true { AccountManager.shared.sessionExpired() }
            phase = .failed(Self.describe(error))
            return
        }

        // Each note is independent: one failing note never blocks the others.
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let dirty = notes.filter(isDirty).map(\.id)
        var failures: [String] = []
        for (i, id) in dirty.enumerated() {
            if Task.isCancelled { break }
            phase = .backingUp(done: i, total: dirty.count)
            do {
                try await backUp(noteID: id, api: api, context: context)
            } catch let e as BackupAPI.APIError where e.status == 401 {
                if e.isSessionExpired { AccountManager.shared.sessionExpired() }
                phase = .failed(Self.describe(e))
                return
            } catch let e as BackupAPI.APIError where !e.isRetryable {
                // Bad request / conflict / too large: park this note until it changes again.
                if let note = fetch(id, in: context) {
                    manifest.notes[id.lowercased, default: .init()].failedModifiedAt = note.modifiedAt
                    manifest.save()
                    failures.append("“\(note.title)”: \(e.message)")
                }
            } catch {
                if let note = fetch(id, in: context) { failures.append("“\(note.title)”: \(Self.describe(error))") }
            }
        }
        if failures.isEmpty {
            lastBackupAt = Date()
            phase = .idle
        } else {
            phase = .failed(failures.count == 1 ? "Couldn’t back up \(failures[0])"
                                                : "\(failures.count) notes couldn’t be backed up. \(failures[0])")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func fetch(_ id: UUID, in context: ModelContext) -> Note? {
        let note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
        guard let note, !note.isDeleted, note.modelContext != nil else { return nil }
        return note
    }

    nonisolated static func sameInstant(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    private func isDirty(_ note: Note) -> Bool {
        let id = note.id.lowercased
        let entry = manifest.notes[id]
        if note.deletedAt != nil { return note.lastBackedUpAt != nil && entry?.tombstoned != true }
        if let parked = entry?.failedModifiedAt, parked == note.modifiedAt { return false }
        guard let last = note.lastBackedUpAt else { return true }
        // lastBackedUpAt is the exact modifiedAt that was uploaded, so any difference is an edit —
        // including one stamped earlier (the device clock moved back).
        if !Self.sameInstant(note.modifiedAt, last) || entry?.needsMetadata == true { return true }
        // A recording's .m4a or transcript that appeared after the last backup.
        let known = entry?.files ?? [:]
        return BackupFiles.list(for: note).contains { f in
            known[f.path] == nil && !manifest.inFlight.keys.contains { $0.hasPrefix("\(id)|\(f.path)|") }
        }
    }

    private func syncSubjects(api: BackupAPI, context: ModelContext) async throws {
        let subjects = (try? context.fetch(FetchDescriptor<Subject>())) ?? []
        let current = Set(subjects.map { $0.id.lowercased })
        var payload = subjects.map { BackupPayload.subject($0) }
        // Subjects deleted on the iPad since the last run → tombstone.
        for gone in manifest.subjects.subtracting(current) {
            let last = manifest.subjectInfo[gone]
            payload.append(["id": gone, "name": last?.name ?? "Subject", "color_hex": last?.colorHex ?? "#8E9BB0", "sort_index": 0,
                            "divider_id": NSNull(), "updated_at": BackupAPI.iso.string(from: Date()),
                            "deleted_at": BackupAPI.iso.string(from: Date())])
        }
        guard !payload.isEmpty else { return }
        _ = try await api.call("PUT", "api/subjects", body: try BackupAPI.json(["subjects": payload]))
        manifest.subjects = current
        // Remember names/colors so a later tombstone keeps them (the server shows tombstoned rows).
        for sub in subjects { manifest.subjectInfo[sub.id.lowercased] = .init(name: sub.name, colorHex: sub.colorHex) }
        manifest.save()
    }

    private func backUp(noteID: UUID, api: BackupAPI, context: ModelContext) async throws {
        let id = noteID.lowercased
        guard let note = fetch(noteID, in: context) else { return }
        let modifiedAt = note.modifiedAt

        if note.deletedAt != nil {
            do { _ = try await api.call("DELETE", "api/notes/\(id)") }
            catch let e as BackupAPI.APIError where e.status == 404 {}
            manifest.notes[id, default: .init()].tombstoned = true
            manifest.save()
            fetch(noteID, in: context)?.lastBackedUpAt = modifiedAt
            try? context.save()
            return
        }
        manifest.notes[id, default: .init()].tombstoned = false

        // 1. Hash files (off the main thread).
        let files = BackupFiles.list(for: note)
        let hashed: [BackupFiles.File] = await Task.detached(priority: .utility) {
            files.compactMap { f in BackupAPI.sha256(of: f.url).map { var h = f; h.sha256 = $0; return h } }
        }.value
        let known = manifest.notes[id]?.files ?? [:]
        let changed = hashed.filter { f in
            known[f.path]?.sha256 != f.sha256 && manifest.inFlight["\(id)|\(f.path)|\(f.sha256!)"].map { Date().timeIntervalSince($0) > 12 * 3600 } != false
        }

        // 2–3. Upload changed files. Small files upload inline; audio goes to the background
        // session and is recorded by its delegate (backgroundUploadFinished), not awaited.
        for start in stride(from: 0, to: changed.count, by: 50) {
            let batch = Array(changed[start..<min(start + 50, changed.count)])
            let resp = try await api.call("POST", "api/uploads", body: try BackupAPI.json([
                "noteId": id,
                "files": batch.map { ["path": $0.path, "sha256": $0.sha256!, "contentType": $0.contentType,
                                      "size": BackupFiles.size(of: $0.url)] as [String: Any] },
            ]))
            for up in resp["uploads"] as? [[String: Any]] ?? [] {
                guard let path = up["path"] as? String, let key = up["key"] as? String,
                      let urlString = up["url"] as? String, let url = URL(string: urlString),
                      let file = batch.first(where: { $0.path == path }), let sha = file.sha256 else { continue }
                let headers = up["headers"] as? [String: String] ?? [:]
                if file.isAudio {
                    manifest.inFlight["\(id)|\(path)|\(sha)"] = Date()
                    manifest.save()
                    BackupUploader.shared.startBackgroundUpload(file: file.url, to: url, headers: headers,
                                                                description: "\(id)|\(path)|\(sha)|\(key)")
                } else {
                    try await BackupUploader.shared.upload(file: file.url, to: url, headers: headers)
                    manifest.notes[id, default: .init()].files[path] = .init(sha256: sha, key: key)
                    manifest.save()
                }
            }
        }

        // 4. Metadata, referencing only files that are actually in the bucket. Transcripts are
        // sent whenever their content differs from what the last successful PUT carried.
        guard let note = fetch(noteID, in: context) else { return }
        let entries = manifest.notes[id]?.files ?? [:]
        let sent = manifest.notes[id]?.sentTranscripts ?? [:]
        var transcriptHashes: [String: String] = [:]
        for f in hashed where f.path.hasPrefix("transcript/") { transcriptHashes[f.path] = f.sha256 }
        let toSend = Set(transcriptHashes.filter { sent[$0.key] != $0.value }.keys)
        let payload = await BackupPayload.note(note, files: entries, sendTranscripts: toSend)
        _ = try await api.call("PUT", "api/notes/\(id)", body: try BackupAPI.json(payload))

        // 5. Mark backed up (stays dirty if edited meanwhile).
        for path in toSend { manifest.notes[id, default: .init()].sentTranscripts[path] = transcriptHashes[path] }
        manifest.notes[id, default: .init()].needsMetadata = false
        manifest.notes[id, default: .init()].failedModifiedAt = nil
        manifest.save()
        if let saved = fetch(noteID, in: context) {
            saved.lastBackedUpAt = modifiedAt
            try? context.save()
            // The server now has these recordings' audio keys → speaker detection can run.
            let withAudio = saved.recordings.filter { entries["audio/\($0.id.lowercased).m4a"] != nil }.map(\.id)
            if !withAudio.isEmpty { SpeakerDetection.shared.metadataSent(noteID: noteID, recordingIDs: withAudio) }
        }
    }

    // MARK: Handoff support

    struct HandoffError: LocalizedError {
        var message: String
        var needsSignIn = false
        var errorDescription: String? { message }
    }

    static var signInMessage: String {
        AccountManager.shared.needsReauth ? "Your sign-in has expired. Sign in again to hand off notes."
                                          : "Sign in to hand off notes — the link is served from your account’s backup."
    }

    /// Backs this one note up now and waits until the server has its latest state.
    /// Runs in its own task, so closing the handoff sheet can't cancel a backup half-way.
    func ensureBackedUp(_ noteID: UUID) async throws {
        guard isConfigured, let context else { throw HandoffError(message: Self.signInMessage, needsSignIn: true) }
        // An explicit handoff is a fresh attempt even if an earlier backup parked this note.
        manifest.notes[noteID.lowercased]?.failedModifiedAt = nil
        func current() -> Bool {
            guard let note = fetch(noteID, in: context), let last = note.lastBackedUpAt else { return false }
            return Self.sameInstant(last, note.modifiedAt) && manifest.notes[noteID.lowercased]?.needsMetadata != true
        }
        var lastError: Error?
        for _ in 0..<3 {
            if current() { return }
            do {
                try await Task { try await self.backUpSingle(noteID) }.value
            } catch let e as BackupAPI.APIError where !e.isRetryable {
                throw HandoffError(message: Self.describe(e))
            } catch {
                lastError = error
            }
        }
        if current() { return }
        throw HandoffError(message: lastError.map(Self.describe) ?? "Couldn’t back up this note. Check your connection and try again.")
    }

    /// One note (plus subjects, which it references), without walking the whole library.
    private func backUpSingle(_ noteID: UUID) async throws {
        guard let api, let context else { throw HandoffError(message: Self.signInMessage, needsSignIn: true) }
        while running { try await Task.sleep(for: .milliseconds(300)) }
        running = true
        defer {
            running = false
            if rerunRequested {
                rerunRequested = false
                Task { await self.backUpNow() }
            }
        }
        try await syncSubjects(api: api, context: context)
        try await backUp(noteID: noteID, api: api, context: context)
    }

    /// Uploads handoff exports (export/notes.pdf, export/page-N.png); returns path → bucket key.
    func uploadExports(noteID: UUID, files: [(path: String, url: URL, contentType: String)]) async throws -> [String: String] {
        guard let api else { throw HandoffError(message: Self.signInMessage, needsSignIn: true) }
        let id = noteID.lowercased
        let hashed: [(path: String, url: URL, contentType: String, sha: String)] = await Task.detached(priority: .userInitiated) {
            files.compactMap { f in BackupAPI.sha256(of: f.url).map { (f.path, f.url, f.contentType, $0) } }
        }.value
        var keys: [String: String] = [:]
        // The server presigns at most 100 files per request.
        for start in stride(from: 0, to: hashed.count, by: 50) {
            let batch = hashed[start..<min(start + 50, hashed.count)]
            let resp = try await api.call("POST", "api/uploads", body: try BackupAPI.json([
                "noteId": id,
                "files": batch.map { ["path": $0.path, "sha256": $0.sha, "contentType": $0.contentType,
                                      "size": BackupFiles.size(of: $0.url)] as [String: Any] },
            ]))
            for up in resp["uploads"] as? [[String: Any]] ?? [] {
                guard let path = up["path"] as? String, let key = up["key"] as? String,
                      let urlString = up["url"] as? String, let url = URL(string: urlString),
                      let file = batch.first(where: { $0.path == path }) else { continue }
                try await BackupUploader.shared.upload(file: file.url, to: url, headers: up["headers"] as? [String: String] ?? [:])
                keys[path] = key
            }
        }
        return keys
    }

    // MARK: Restore (fresh install)

    /// Downloads notes that aren't on this iPad. A note is only inserted once all of its
    /// files arrived intact; otherwise it's skipped (and can be retried) — never half-restored.
    func restore() async {
        guard !suspended else { return }
        await tracked { await self.performRestore() }
    }

    private func performRestore() async {
        guard !suspended, !running, let api, let context else { return }
        running = true
        defer { running = false }
        phase = .restoring("Fetching your notes…")
        do {
            let existingNotes = Set(((try? context.fetch(FetchDescriptor<Note>())) ?? []).map(\.id))
            var subjectsByID: [String: Subject] = [:]
            for s in (try? context.fetch(FetchDescriptor<Subject>())) ?? [] { subjectsByID[s.id.lowercased] = s }

            var cursor: String?
            var restored = 0
            var skipped = 0
            repeat {
                var q = [URLQueryItem(name: "urls", value: "1"), URLQueryItem(name: "limit", value: "100")]
                if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
                let page = try await api.call("GET", "api/notes", query: q)

                for s in page["subjects"] as? [[String: Any]] ?? [] {
                    guard let sid = s["id"] as? String, subjectsByID[sid] == nil, s["deleted_at"] is NSNull || s["deleted_at"] == nil,
                          let uuid = UUID(uuidString: sid) else { continue }
                    let subject = Subject(name: s["name"] as? String ?? "Subject", colorHex: s["color_hex"] as? String ?? "#4A90E2",
                                          sortIndex: s["sort_index"] as? Int ?? 0)
                    subject.id = uuid
                    context.insert(subject)
                    subjectsByID[sid] = subject
                }

                for item in page["notes"] as? [[String: Any]] ?? [] {
                    if Task.isCancelled { break }
                    guard let n = item["note"] as? [String: Any], let nid = n["id"] as? String,
                          let noteID = UUID(uuidString: nid), !existingNotes.contains(noteID) else { continue }
                    phase = .restoring("Restoring “\(n["title"] as? String ?? "note")”…")
                    let note = BackupPayload.makeNote(from: item, subjects: subjectsByID)
                    let complete = (try? await BackupPayload.downloadFiles(item, note: note, api: api)) ?? false
                    guard complete else {
                        NoteFiles.deleteNoteFolder(note.id)
                        skipped += 1
                        continue
                    }
                    let recs = item["recordings"] as? [[String: Any]] ?? []
                    if recs.contains(where: { $0["has_transcript"] as? Bool == true }),
                       let full = try? await api.call("GET", "api/notes/\(nid)") {
                        BackupPayload.writeTranscripts(full, note: note)
                    }
                    BackupPayload.attachTranscripts(note)
                    context.insert(note)
                    let pdf = note.pdfBackgroundFile.flatMap { CGPDFDocument(NoteFiles.folder(note.id).appendingPathComponent($0) as CFURL) }
                    ThumbnailRenderer.render(drawing: DrawingStore.load(note.id), paper: note.paper, noteID: note.id, pdf: pdf)
                    note.thumbnailVersion += 1
                    manifest.notes[nid] = BackupPayload.manifestEntry(for: note, item: item)
                    restored += 1
                }
                try? context.save()
                manifest.save()
                cursor = page["next_cursor"] as? String
            } while cursor != nil
            var summary = restored == 0 ? "Nothing new to restore." : "Restored \(restored) note\(restored == 1 ? "" : "s")."
            if skipped > 0 { summary += " \(skipped) couldn’t be downloaded; try Restore again." }
            lastRestoreSummary = summary
            phase = .idle
        } catch {
            phase = .failed(Self.describe(error))
        }
    }
}

// MARK: - Manifest of what's in the bucket

nonisolated struct BackupManifest: Codable {
    struct FileEntry: Codable, Equatable { var sha256: String; var key: String }
    struct NoteEntry: Codable {
        /// Files known to be in the bucket (path → hash + key).
        var files: [String: FileEntry] = [:]
        /// Transcript hashes carried by the last successful metadata PUT.
        var sentTranscripts: [String: String] = [:]
        var tombstoned = false
        /// A background upload landed; the metadata must be re-sent to reference it.
        var needsMetadata = false
        /// Parked after a non-retryable error at this modifiedAt; retried once the note changes.
        var failedModifiedAt: Date?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = try c.decodeIfPresent([String: FileEntry].self, forKey: .files) ?? [:]
            sentTranscripts = try c.decodeIfPresent([String: String].self, forKey: .sentTranscripts) ?? [:]
            tombstoned = try c.decodeIfPresent(Bool.self, forKey: .tombstoned) ?? false
            needsMetadata = try c.decodeIfPresent(Bool.self, forKey: .needsMetadata) ?? false
            failedModifiedAt = try c.decodeIfPresent(Date.self, forKey: .failedModifiedAt)
        }
    }
    var notes: [String: NoteEntry] = [:]
    var subjects: Set<String> = []
    var pendingDeletes: Set<String> = []
    /// Background uploads in progress: "noteId|path|sha" → started.
    var inFlight: [String: Date] = [:]
    struct SubjectInfo: Codable { var name: String; var colorHex: String }
    var subjectInfo: [String: SubjectInfo] = [:]

    init() {}

    // Tolerant decoding: fields added later default instead of discarding the manifest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([String: NoteEntry].self, forKey: .notes) ?? [:]
        subjects = try c.decodeIfPresent(Set<String>.self, forKey: .subjects) ?? []
        pendingDeletes = try c.decodeIfPresent(Set<String>.self, forKey: .pendingDeletes) ?? []
        inFlight = try c.decodeIfPresent([String: Date].self, forKey: .inFlight) ?? [:]
        subjectInfo = try c.decodeIfPresent([String: SubjectInfo].self, forKey: .subjectInfo) ?? [:]
    }

    static var url: URL { StorageScope.current.manifestURL }
    static func load() -> BackupManifest {
        (try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: url))) ?? BackupManifest()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - Files per note (server key layout mirrors Notes/<id>/)

nonisolated enum BackupFiles {
    struct File: Sendable {
        var path: String          // server path, lowercase ids: "audio/<recId>.m4a"
        var url: URL              // local file
        var contentType: String
        var isAudio: Bool
        var sha256: String?
    }

    /// Bytes on disk; the server signs this exact Content-Length into the upload URL.
    nonisolated static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    @MainActor
    static func list(for note: Note) -> [File] {
        let fm = FileManager.default
        var out: [File] = []
        func add(_ path: String, _ url: URL, _ type: String, audio: Bool = false) {
            if fm.fileExists(atPath: url.path) { out.append(File(path: path, url: url, contentType: type, isAudio: audio)) }
        }
        add("drawing.pkdrawing", NoteFiles.drawingURL(note.id), "application/octet-stream")
        add("thumb.png", NoteFiles.thumbURL(note.id), "image/png")
        if let pdf = note.pdfBackgroundFile {
            add("background.pdf", NoteFiles.folder(note.id).appendingPathComponent(pdf), "application/pdf")
        }
        for rec in note.recordings where rec.duration > 0 {
            // Only the compressed .m4a is backed up (uploaded once the transcode finishes).
            add("audio/\(rec.id.lowercased).m4a", NoteFiles.audioURL(noteID: note.id, recordingID: rec.id), "audio/mp4", audio: true)
            add("transcript/\(rec.id.lowercased).json", NoteFiles.transcriptURL(noteID: note.id, recordingID: rec.id), "application/json")
        }
        for e in note.elements where e.kind == .image {
            if let name = e.imageFileName {
                add("images/\(e.id.lowercased).jpg", NoteFiles.imagesFolder(note.id).appendingPathComponent(name), "image/jpeg")
            }
        }
        return out
    }
}

extension UUID {
    nonisolated var lowercased: String { uuidString.lowercased() }
}
