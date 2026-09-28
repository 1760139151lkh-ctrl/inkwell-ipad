import Foundation
import PencilKit
import SwiftData
import UIKit

/// Builds the server JSON (server/README.md) and rebuilds local models on restore.
@MainActor
enum BackupPayload {
    static func iso(_ d: Date?) -> Any { d.map { BackupAPI.iso.string(from: $0) } ?? NSNull() }

    static func subject(_ s: Subject) -> [String: Any] {
        ["id": s.id.lowercased, "name": s.name, "color_hex": s.colorHex, "sort_index": s.sortIndex,
         "divider_id": s.divider.map { $0.id.lowercased } ?? NSNull(),
         "updated_at": iso(Date()), "deleted_at": NSNull()]
    }

    static func note(_ note: Note, files: [String: BackupManifest.FileEntry], sendTranscripts: Set<String>) async -> [String: Any] {
        let id = note.id.lowercased
        func key(_ path: String) -> Any { files[path]?.key ?? NSNull() }
        func sha(_ path: String) -> Any { files[path]?.sha256 ?? NSNull() }
        let p = note.paper
        var noteJSON: [String: Any] = [
            "id": id,
            "subject_id": note.subject.map { $0.id.lowercased } ?? NSNull(),
            "title": note.title,
            // `paper` is free-form JSON on the server; the view mode rides along so it survives restore.
            "paper": ["style": p.style.rawValue, "color": p.color.rawValue, "spacing": p.spacing.rawValue, "landscape": p.landscape,
                      "view_mode": note.viewModeRaw ?? NSNull()],
            "page_count": note.pageCount,
            "bookmarked_pages": note.bookmarkedPages,
            "created_at": iso(note.createdAt),
            "modified_at": iso(note.modifiedAt),
            "deleted_at": NSNull(),
            "speaker_names": note.speakerNames,
            "drawing_key": key("drawing.pkdrawing"), "drawing_sha256": sha("drawing.pkdrawing"),
            "thumb_key": key("thumb.png"),
            "background_key": key("background.pdf"),
        ]

        let recordings = note.orderedRecordings.filter { $0.duration > 0 }
        let recs: [[String: Any]] = recordings.map { r in
            let path = "audio/\(r.id.lowercased).m4a"
            return ["id": r.id.lowercased, "ord": r.order, "name": r.name, "started_at": iso(r.startedAt),
                    "duration_s": r.duration, "audio_key": key(path), "audio_sha256": sha(path),
                    "transcript_status": r.transcriptStatus.rawValue, "deleted_at": NSNull()]
        }
        var transcripts: [[String: Any]] = []
        for r in recordings where sendTranscripts.contains("transcript/\(r.id.lowercased).json") {
            guard let t = TranscriptStore.load(noteID: note.id, recordingID: r.id),
                  let data = try? JSONEncoder().encode(t.segments),
                  let segs = try? JSONSerialization.jsonObject(with: data) else { continue }
            transcripts.append(["recording_id": r.id.lowercased, "locale": t.locale, "engine": t.engine,
                                "segments": segs, "full_text": t.fullText])
        }
        let elements: [[String: Any]] = note.elements.map { e in
            var frame: [String: Any] = ["x": e.frameX, "y": e.frameY, "w": e.frameW, "h": e.frameH]
            if e.kind == .text {
                frame["font_size"] = e.fontSize ?? 16
                frame["bold"] = e.isBold ?? false
                frame["color"] = e.colorHex ?? "#1A1A1A"
            }
            return ["id": e.id.lowercased, "kind": e.kind.rawValue, "frame": frame, "created_at": iso(e.createdAt),
                    "text": e.text ?? NSNull(), "file_key": e.kind == .image ? key("images/\(e.id.lowercased).jpg") : NSNull(),
                    "deleted_at": NSNull()]
        }

        // Per-stroke timing + page + bounds, no ink (PRD §8.3 strokes_index, the Phase 3 join key).
        let timeline = NoteTimeline(recordings.map { ($0.id, $0.startedAt, $0.duration) })
        let noteID = note.id
        let geo = PageGeometry(paper: note.paper)
        let strokesData: Data = await Task.detached(priority: .utility) {
            let drawing = DrawingStore.load(noteID)
            let rows = drawing.strokes.enumerated().map { i, s -> [String: Any] in
                let b = s.renderBounds
                let date = s.path.creationDate
                return ["i": i, "created_at": BackupAPI.iso.string(from: date),
                        "t_note": timeline.timelineTime(of: date).map { ($0 * 1000).rounded() / 1000 } as Any? ?? NSNull(),
                        "page": geo.pageIndex(forY: b.midY),
                        "bbox": [b.minX, b.minY, b.width, b.height].map { ($0 * 10).rounded() / 10 }]
            }
            return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        }.value
        let strokes = (try? JSONSerialization.jsonObject(with: strokesData)) ?? []

        return ["subject": note.subject.map(subject) ?? NSNull(), "note": noteJSON, "recordings": recs,
                "transcripts": transcripts, "strokes_index": ["strokes": strokes], "elements": elements]
    }

    // MARK: Restore

    static func makeNote(from item: [String: Any], subjects: [String: Subject]) -> Note {
        let n = item["note"] as? [String: Any] ?? [:]
        let paperJSON = n["paper"] as? [String: Any] ?? [:]
        let paper = Paper(style: PaperStyle(rawValue: paperJSON["style"] as? String ?? "") ?? .blank,
                          color: PaperColor(rawValue: paperJSON["color"] as? String ?? "") ?? .white,
                          spacing: PaperSpacing(rawValue: paperJSON["spacing"] as? String ?? "") ?? .medium,
                          landscape: paperJSON["landscape"] as? Bool ?? false)
        let note = Note(title: n["title"] as? String ?? "Note", subject: (n["subject_id"] as? String).flatMap { subjects[$0] }, paper: paper)
        note.id = UUID(uuidString: n["id"] as? String ?? "") ?? UUID()
        note.createdAt = BackupAPI.date(n["created_at"]) ?? Date()
        note.modifiedAt = BackupAPI.date(n["modified_at"]) ?? Date()
        note.deletedAt = BackupAPI.date(n["deleted_at"])
        note.pageCount = n["page_count"] as? Int ?? 1
        note.bookmarkedPages = n["bookmarked_pages"] as? [Int] ?? []
        note.viewModeRaw = paperJSON["view_mode"] as? String
        if let names = n["speaker_names"] as? [String: String] { note.speakerNames = names }
        if n["background_key"] is String { note.pdfBackgroundFile = "background.pdf" }
        note.lastBackedUpAt = note.modifiedAt

        for r in item["recordings"] as? [[String: Any]] ?? [] where r["deleted_at"] == nil || r["deleted_at"] is NSNull {
            guard let rid = UUID(uuidString: r["id"] as? String ?? "") else { continue }
            let rec = Recording(note: note, order: r["ord"] as? Int ?? 0, startedAt: BackupAPI.date(r["started_at"]) ?? note.createdAt)
            rec.id = rid
            rec.fileName = "\(rid.uuidString).m4a"
            rec.name = r["name"] as? String ?? rec.name
            rec.duration = (r["duration_s"] as? Double) ?? Double(r["duration_s"] as? Int ?? 0)
            rec.transcriptStatus = TranscriptStatus(rawValue: r["transcript_status"] as? String ?? "") ?? .none
            note.recordings.append(rec)
        }
        for e in item["elements"] as? [[String: Any]] ?? [] where e["deleted_at"] == nil || e["deleted_at"] is NSNull {
            guard let eid = UUID(uuidString: e["id"] as? String ?? "") else { continue }
            let f = e["frame"] as? [String: Any] ?? [:]
            func num(_ k: String) -> Double { (f[k] as? Double) ?? Double(f[k] as? Int ?? 0) }
            let kind = ElementKind(rawValue: e["kind"] as? String ?? "") ?? .text
            let el = PageElement(kind: kind, frame: CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h")))
            el.id = eid
            el.createdAt = BackupAPI.date(e["created_at"]) ?? note.createdAt
            el.text = e["text"] as? String
            if kind == .text {
                el.fontSize = f["font_size"] as? Double
                el.isBold = f["bold"] as? Bool
                el.colorHex = f["color"] as? String
            } else {
                el.imageFileName = "\(eid.uuidString).jpg"
            }
            note.elements.append(el)
        }
        return note
    }

    /// Downloads every file in `file_keys` into the note folder, verifying SHA-256 where known.
    /// Returns false if any file is missing or corrupt (the caller then skips the note).
    static func downloadFiles(_ item: [String: Any], note: Note, api: BackupAPI) async throws -> Bool {
        let keys = item["file_keys"] as? [String] ?? []
        var urls = item["urls"] as? [String: String] ?? [:]
        let missing = keys.filter { urls[$0] == nil }
        if !missing.isEmpty {
            let resp = try await api.call("POST", "api/downloads", body: try BackupAPI.json(["keys": missing]))
            for d in resp["downloads"] as? [[String: Any]] ?? [] {
                if let k = d["key"] as? String, let u = d["url"] as? String { urls[k] = u }
            }
        }
        let prefix = "notes/\(note.id.lowercased)/"
        for key in keys {
            guard key.hasPrefix(prefix), let dest = localURL(forPath: String(key.dropFirst(prefix.count)), note: note) else { continue }
            guard let s = urls[key], let url = URL(string: s) else { return false }
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            if let expected = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-amz-meta-sha256"),
               let actual = BackupAPI.sha256(of: tmp), expected.lowercased() != actual {
                return false   // corrupted download: never restore bad bytes
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return true
    }

    /// Manifest for a freshly restored note, seeded from the server's own keys and hashes so
    /// the next backup never re-uploads (or nulls out) what the server already has.
    static func manifestEntry(for note: Note, item: [String: Any]) -> BackupManifest.NoteEntry {
        var entry = BackupManifest.NoteEntry()
        let nid = note.id.lowercased
        let n = item["note"] as? [String: Any] ?? [:]
        var serverSHA: [String: String] = [:]
        if let sha = n["drawing_sha256"] as? String { serverSHA["drawing.pkdrawing"] = sha }
        for r in item["recordings"] as? [[String: Any]] ?? [] {
            if let rid = r["id"] as? String, let sha = r["audio_sha256"] as? String { serverSHA["audio/\(rid).m4a"] = sha }
        }
        for key in item["file_keys"] as? [String] ?? [] where key.hasPrefix("notes/\(nid)/") {
            let path = String(key.dropFirst("notes/\(nid)/".count))
            guard let local = localURL(forPath: path, note: note) else { continue }
            if let sha = serverSHA[path] ?? BackupAPI.sha256(of: local) { entry.files[path] = .init(sha256: sha, key: key) }
        }
        // Transcripts came from Postgres; mark their local sidecars as already sent.
        for rec in note.recordings {
            let path = "transcript/\(rec.id.lowercased).json"
            let url = NoteFiles.transcriptURL(noteID: note.id, recordingID: rec.id)
            if let sha = BackupAPI.sha256(of: url) {
                entry.sentTranscripts[path] = sha
                entry.files[path] = .init(sha256: sha, key: "notes/\(nid)/\(path)")
            }
        }
        return entry
    }

    /// Server path (lowercase ids) → local file (uppercase UUID names, PRD §8.2 layout).
    static func localURL(forPath path: String, note: Note) -> URL? {
        func uuid(_ file: String) -> UUID? { UUID(uuidString: (file as NSString).deletingPathExtension) }
        switch path {
        case "drawing.pkdrawing": return NoteFiles.drawingURL(note.id)
        case "thumb.png": return NoteFiles.thumbURL(note.id)
        case "background.pdf": return NoteFiles.folder(note.id).appendingPathComponent("background.pdf")
        default:
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2, let id = uuid(parts[1]) else { return nil }
            switch parts[0] {
            case "audio": return NoteFiles.audioURL(noteID: note.id, recordingID: id)
            case "transcript": return NoteFiles.transcriptURL(noteID: note.id, recordingID: id)
            case "images": return NoteFiles.imagesFolder(note.id).appendingPathComponent("\(id.uuidString).jpg")
            default: return nil
            }
        }
    }

    /// Transcripts live in Postgres (with word timings); write them back as the local JSON sidecars.
    static func writeTranscripts(_ full: [String: Any], note: Note) {
        for t in full["transcripts"] as? [[String: Any]] ?? [] {
            guard let rid = UUID(uuidString: t["recording_id"] as? String ?? ""),
                  note.recordings.contains(where: { $0.id == rid }),
                  let segs = t["segments"], let data = try? JSONSerialization.data(withJSONObject: segs),
                  let segments = try? JSONDecoder().decode([Transcript.Segment].self, from: data) else { continue }
            let transcript = Transcript(recordingId: rid.uuidString, locale: t["locale"] as? String ?? "en-US",
                                        engine: t["engine"] as? String ?? "SpeechTranscriber", segments: segments)
            TranscriptStore.save(transcript, noteID: note.id)
        }
    }

    static func attachTranscripts(_ note: Note) {
        for rec in note.recordings {
            if let t = TranscriptStore.load(noteID: note.id, recordingID: rec.id), !t.segments.isEmpty {
                rec.transcriptText = t.fullText
                rec.transcriptStatus = .complete
            }
        }
    }
}

// MARK: - Uploads (background session for audio)

/// PUTs files to presigned URLs. Audio goes through a background URLSession so a 2-hour
/// recording finishes uploading after the app is closed (PRD §8.3). Each background task
/// carries "noteId|path|sha|key" in its description, so its result is recorded even if the
/// app was relaunched in between.
final class BackupUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackupUploader()
    static let backgroundID = "studio.persimmons.inkwell.audio-upload"

    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var finishedEventsEarly = false

    private lazy var background: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    struct UploadError: LocalizedError {
        var status: Int
        var errorDescription: String? { "A file upload failed (\(status))." }
    }

    /// Foreground upload (drawings, thumbnails, images, transcripts).
    nonisolated func upload(file: URL, to url: URL, headers: [String: String]) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = 120
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UploadError(status: status) }
    }

    /// Background upload (audio). Not awaited; completion is reported to the backup engine.
    nonisolated func startBackgroundUpload(file: URL, to url: URL, headers: [String: String], description: String) {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = background.uploadTask(with: req, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && (200..<300).contains(status)
        let parts = (task.taskDescription ?? "").split(separator: "|").map(String.init)
        guard parts.count == 4 else { return }
        Task { @MainActor in
            BackupEngine.shared.backgroundUploadFinished(noteID: parts[0], path: parts[1], sha256: parts[2], key: parts[3], success: ok)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = lock.withLock {
            if let c = completion { completion = nil; return c }
            finishedEventsEarly = true
            return nil
        }
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    /// Called by the app delegate; if events already finished, completes right away.
    nonisolated func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        let runNow: Bool = lock.withLock {
            if finishedEventsEarly { finishedEventsEarly = false; return true }
            completion = handler
            return false
        }
        if runNow { DispatchQueue.main.async(execute: handler) }
    }

    /// Recreate the session on launch so pending events are delivered.
    nonisolated func reconnect() { _ = background }
}
