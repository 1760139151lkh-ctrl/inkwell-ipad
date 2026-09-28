import Foundation
import SwiftData

/// Moves every note made on this iPad while signed out into an account's store: the first
/// time you sign in, your existing notes become yours rather than being left behind.
///
/// Crash-safe ordering: copy into the destination and save → move each note's files →
/// only then delete the originals. Re-running after an interruption skips notes the
/// destination already has and still moves any files left behind.
@MainActor enum StoreMerger {
    struct Result { var notes: Int; var subjects: Int }

    static func adopt(from source: StorageScope, into dest: StorageScope, keepManifest: Bool) throws -> Result {
        try FileManager.default.createDirectory(at: dest.directory, withIntermediateDirectories: true)
        let src = ModelContext(try AppSession.openContainer(source))
        let dst = ModelContext(try AppSession.openContainer(dest))

        let dividers = try src.fetch(FetchDescriptor<SubjectDivider>())
        let subjects = try src.fetch(FetchDescriptor<Subject>())
        let notes = try src.fetch(FetchDescriptor<Note>())
        guard !notes.isEmpty || !subjects.isEmpty || !dividers.isEmpty else {
            mergeManifest(from: source, into: dest, keep: false)
            return Result(notes: 0, subjects: 0)
        }

        // 1. Copy the object graph (ids preserved, so a backup claimed with the notes still matches).
        var dividerMap: [UUID: SubjectDivider] = [:]
        for d in try dst.fetch(FetchDescriptor<SubjectDivider>()) { dividerMap[d.id] = d }
        for d in dividers where dividerMap[d.id] == nil {
            let copy = SubjectDivider(name: d.name, sortIndex: d.sortIndex)
            copy.id = d.id
            copy.isCollapsed = d.isCollapsed
            dst.insert(copy)
            dividerMap[d.id] = copy
        }
        var subjectMap: [UUID: Subject] = [:]
        for s in try dst.fetch(FetchDescriptor<Subject>()) { subjectMap[s.id] = s }
        var newSubjects = 0
        for s in subjects where subjectMap[s.id] == nil {
            let copy = Subject(name: s.name, colorHex: s.colorHex, sortIndex: s.sortIndex)
            copy.id = s.id
            copy.divider = s.divider.flatMap { dividerMap[$0.id] }
            dst.insert(copy)
            subjectMap[s.id] = copy
            newSubjects += 1
        }
        let existing = Set(try dst.fetch(FetchDescriptor<Note>()).map(\.id))
        var newNotes = 0
        for n in notes where !existing.contains(n.id) {
            _ = copy(n, subject: n.subject.flatMap { subjectMap[$0.id] }, into: dst)
            newNotes += 1
        }
        try dst.save()

        // 2. Files: Notes/<id>/ (drawing, audio, transcripts, images, PDF).
        let fm = FileManager.default
        try fm.createDirectory(at: dest.notesRoot, withIntermediateDirectories: true)
        for n in notes {
            let from = source.notesRoot.appendingPathComponent(n.id.uuidString, isDirectory: true)
            let to = dest.notesRoot.appendingPathComponent(n.id.uuidString, isDirectory: true)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try fm.moveItem(at: from, to: to)
        }

        // 3. Backup bookkeeping, then remove the originals.
        mergeManifest(from: source, into: dest, keep: keepManifest)
        for n in notes { src.delete(n) }
        for s in subjects { src.delete(s) }
        for d in dividers { src.delete(d) }
        try src.save()
        return Result(notes: newNotes, subjects: newSubjects)
    }

    private static func copy(_ n: Note, subject: Subject?, into ctx: ModelContext) -> Note {
        let c = Note(title: n.title, subject: subject, paper: n.paper)
        c.id = n.id
        ctx.insert(c)
        c.createdAt = n.createdAt
        c.modifiedAt = n.modifiedAt
        c.pageCount = n.pageCount
        c.bookmarkedPages = n.bookmarkedPages
        c.pdfBackgroundFile = n.pdfBackgroundFile
        c.deletedAt = n.deletedAt
        c.lastBackedUpAt = n.lastBackedUpAt
        c.thumbnailVersion = n.thumbnailVersion
        c.viewModeRaw = n.viewModeRaw
        c.speakerNamesJSON = n.speakerNamesJSON
        for r in n.recordings {
            let rc = Recording(note: c, order: r.order, startedAt: r.startedAt)
            rc.id = r.id
            rc.name = r.name
            rc.duration = r.duration
            rc.fileName = r.fileName
            rc.transcriptStatusRaw = r.transcriptStatusRaw
            rc.transcriptText = r.transcriptText
            ctx.insert(rc)
        }
        for e in n.elements {
            let ec = PageElement(kind: e.kind, frame: e.frame)
            ec.id = e.id
            ec.note = c
            ec.createdAt = e.createdAt
            ec.text = e.text
            ec.imageFileName = e.imageFileName
            ec.fontSize = e.fontSize
            ec.isBold = e.isBold
            ec.colorHex = e.colorHex
            ctx.insert(ec)
        }
        return c
    }

    /// With `keep` (the device's old backup now belongs to this account) the upload records
    /// carry over, so nothing is re-uploaded. Otherwise they're dropped and the notes back up
    /// fresh into the account.
    private static func mergeManifest(from source: StorageScope, into dest: StorageScope, keep: Bool) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: source.manifestURL) }
        guard keep, let data = try? Data(contentsOf: source.manifestURL),
              let old = try? JSONDecoder().decode(BackupManifest.self, from: data) else { return }
        var merged = (try? Data(contentsOf: dest.manifestURL)).flatMap { try? JSONDecoder().decode(BackupManifest.self, from: $0) } ?? BackupManifest()
        for (id, entry) in old.notes where merged.notes[id] == nil { merged.notes[id] = entry }
        merged.subjects.formUnion(old.subjects)
        for (id, info) in old.subjectInfo where merged.subjectInfo[id] == nil { merged.subjectInfo[id] = info }
        merged.pendingDeletes.formUnion(old.pendingDeletes)
        if let out = try? JSONEncoder().encode(merged) { try? out.write(to: dest.manifestURL, options: .atomic) }
    }
}
