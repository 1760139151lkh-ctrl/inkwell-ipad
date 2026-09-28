import Foundation
import Observation
import SwiftData
import SwiftUI

enum LibrarySelection: Hashable {
    case all
    case subject(UUID)
}

/// Library-level state: what's selected, which note is open, and the open editor.
@MainActor @Observable final class AppModel {
    let context: ModelContext

    var selection: LibrarySelection = .all
    var libraryVisible = true
    /// True when the library slides over the editor (narrow window / portrait).
    var libraryIsOverlay = false
    var searchText = ""
    var isSearching = false
    var showSettings = false
    /// Asks the sidebar to open the New Subject sheet (keyboard shortcut / debug).
    var requestNewSubject = false
    var settingsSection: SettingsSection = .document
    private(set) var editor: EditorModel?

    init(context: ModelContext) {
        self.context = context
        AudioRecorder.shared.onRecordingFinished = { [weak self] noteID in
            guard let editor = self?.editor, editor.note.id == noteID else { return }
            Task { await editor.reloadAudio() }
        }
    }

    var openNoteID: UUID? { editor?.note.id }

    // MARK: - Notes

    func open(_ note: Note) {
        guard note.id != editor?.note.id else { return }
        editor?.close()
        editor = EditorModel(note: note, context: context)
        UserDefaults.standard.set(note.id.uuidString, forKey: "lastOpenNote.\(StorageScope.current.id)")
    }

    /// Reopens the note that was open when the app last quit.
    func restoreLastNote() {
        guard editor == nil, let s = UserDefaults.standard.string(forKey: "lastOpenNote.\(StorageScope.current.id)"), let id = UUID(uuidString: s),
              let note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })).first
        else { return }
        if let subjectID = note.subject?.id { selection = .subject(subjectID) }
        open(note)
    }

    /// Import PDF… (PRD §6.3): a new note whose pages are the PDF's pages.
    func importPDF(_ url: URL) {
        var subject: Subject?
        if case .subject(let id) = selection { subject = fetchSubject(id) }
        let title = url.deletingPathExtension().lastPathComponent
        let note = Note(title: title, subject: subject, paper: Paper())
        context.insert(note)
        guard PDFImport.attach(url, to: note) else {
            context.delete(note)
            return
        }
        try? context.save()
        let pdf = note.pdfBackgroundFile.flatMap { CGPDFDocument(NoteFiles.folder(note.id).appendingPathComponent($0) as CFURL) }
        ThumbnailRenderer.render(drawing: .init(), paper: note.paper, noteID: note.id, pdf: pdf)
        note.thumbnailVersion += 1
        open(note)
    }

    func closeEditor() {
        editor?.close()
        editor = nil
    }

    @discardableResult
    func createNote() -> Note {
        var subject: Subject?
        if case .subject(let id) = selection { subject = fetchSubject(id) }
        let settings = AppSettings.shared
        let note = Note(title: settings.newNoteTitle(), subject: subject, paper: settings.defaultPaper)
        context.insert(note)
        try? context.save()
        ThumbnailRenderer.render(drawing: .init(), paper: note.paper, noteID: note.id)
        note.thumbnailVersion += 1
        open(note)
        return note
    }

    func duplicate(_ note: Note) {
        editor?.flush()
        let copy = Note(title: note.title + " copy", subject: note.subject, paper: note.paper)
        copy.pageCount = note.pageCount
        copy.bookmarkedPages = note.bookmarkedPages
        copy.pdfBackgroundFile = note.pdfBackgroundFile
        copy.viewModeRaw = note.viewModeRaw
        context.insert(copy)
        NoteFiles.copyNoteFolder(from: note.id, to: copy.id)
        // Clone text boxes and images with fresh ids (image files renamed to match).
        let images = NoteFiles.imagesFolder(copy.id)
        for e in note.elements {
            let clone = PageElement(kind: e.kind, frame: e.frame)
            clone.createdAt = e.createdAt
            clone.text = e.text
            clone.fontSize = e.fontSize
            clone.isBold = e.isBold
            clone.colorHex = e.colorHex
            if let name = e.imageFileName {
                let newName = "\(clone.id.uuidString).jpg"
                try? FileManager.default.moveItem(at: images.appendingPathComponent(name), to: images.appendingPathComponent(newName))
                clone.imageFileName = newName
            }
            context.insert(clone)
            copy.elements.append(clone)
        }
        copy.thumbnailVersion = 1
        try? context.save()
    }

    /// Moves to Recently Deleted (kept 30 days, PRD §9).
    func delete(_ note: Note) {
        if AudioRecorder.shared.noteID == note.id { Task { await AudioRecorder.shared.stop() } }
        if editor?.note.id == note.id { closeEditor() }
        note.deletedAt = Date()
        try? context.save()
        BackupEngine.shared.noteChanged()
    }

    func restore(_ note: Note) {
        note.deletedAt = nil
        note.modifiedAt = Date()   // re-send to the server, which un-tombstones it
        if let subject = note.subject, (try? context.fetch(FetchDescriptor<Subject>()))?.contains(where: { $0.id == subject.id }) != true {
            note.subject = nil
        }
        try? context.save()
    }

    func deletePermanently(_ note: Note) {
        if note.lastBackedUpAt != nil { BackupEngine.shared.notePermanentlyDeleted(note.id) }
        NoteFiles.deleteNoteFolder(note.id)
        context.delete(note)
        try? context.save()
    }

    func move(_ note: Note, to subject: Subject?) {
        note.subject = subject
        note.modifiedAt = Date()
        try? context.save()
        BackupEngine.shared.noteChanged()
    }

    func rename(_ note: Note, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = t.isEmpty ? AppSettings.shared.newNoteTitle(at: note.createdAt) : t
        note.modifiedAt = Date()
        if editor?.note.id == note.id { editor?.canvas.setTitle(note.title) }
        try? context.save()
    }

    // MARK: - Subjects

    func fetchSubject(_ id: UUID) -> Subject? {
        try? context.fetch(FetchDescriptor<Subject>(predicate: #Predicate { $0.id == id })).first
    }

    func createSubject(name: String, colorHex: String) {
        let count = (try? context.fetchCount(FetchDescriptor<Subject>())) ?? 0
        let s = Subject(name: name, colorHex: colorHex, sortIndex: count)
        context.insert(s)
        try? context.save()
        selection = .subject(s.id)
    }

    /// Deleting a subject leaves its notes Unfiled (still in All Notes).
    func deleteSubject(_ subject: Subject) {
        for note in subject.notes {
            note.subject = nil
            note.modifiedAt = Date()
        }
        if selection == .subject(subject.id) { selection = .all }
        context.delete(subject)
        try? context.save()
    }

    // MARK: - Maintenance

    static func purgeRecentlyDeleted(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil })
        for note in (try? context.fetch(descriptor)) ?? [] where (note.deletedAt ?? .now) < cutoff {
            NoteFiles.deleteNoteFolder(note.id)
            context.delete(note)
        }
        try? context.save()
    }
}
