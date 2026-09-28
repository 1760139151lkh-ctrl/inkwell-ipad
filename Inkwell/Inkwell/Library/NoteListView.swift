import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Note list column (PRD §6.3).
struct NoteListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil }) private var allNotes: [Note]
    @Query(sort: \Subject.sortIndex) private var subjects: [Subject]

    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var renaming: Note?
    @State private var renameText = ""
    @State private var pendingDelete: [Note] = []
    @State private var movingNotes: [Note] = []
    @State private var importingPDF = false

    private var settings: AppSettings { .shared }

    private var heading: String {
        if model.isSearching { return "Search" }
        switch model.selection {
        case .all: return "Notes"
        case .subject(let id): return subjects.first { $0.id == id }?.name ?? "Notes"
        }
    }

    private var notes: [Note] {
        let base: [Note]
        if model.isSearching {
            let q = model.searchText.trimmingCharacters(in: .whitespaces)
            base = q.isEmpty ? [] : allNotes.filter { note in
                note.title.localizedCaseInsensitiveContains(q)
                    || note.recordings.contains { $0.transcriptText?.localizedCaseInsensitiveContains(q) == true }
            }
        } else {
            switch model.selection {
            case .all: base = allNotes
            case .subject(let id): base = allNotes.filter { $0.subject?.id == id }
            }
        }
        switch settings.sortOrder {
        case .modified: return base.sorted { $0.modifiedAt > $1.modifiedAt }
        case .created: return base.sorted { $0.createdAt > $1.createdAt }
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(heading)
                .font(Theme.serif(26, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)

            if notes.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(notes) { note in
                        row(note)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            if selecting { selectionBar }
        }
        .background(Theme.noteList)
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { model.importPDF(url) }
        }
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let n = renaming { model.rename(n, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                pendingDelete.forEach(model.delete)
                pendingDelete = []
                selecting = false
                selectedIDs = []
            }
        } message: {
            Text("Deleted notes stay in Recently Deleted for 30 days.")
        }
        .sheet(isPresented: Binding(get: { !movingNotes.isEmpty }, set: { if !$0 { movingNotes = [] } })) {
            MoveToSubjectSheet(notes: movingNotes) {
                movingNotes = []
                selecting = false
                selectedIDs = []
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].title)”?" : "Delete \(pendingDelete.count) notes?"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Spacer()
            if selecting {
                Button("Done") {
                    selecting = false
                    selectedIDs = []
                }
                .font(.system(size: 15, weight: .semibold))
            } else {
                Menu {
                    Section("Sort By") {
                        ForEach(NoteSort.allCases) { sort in
                            Button {
                                settings.sortOrder = sort
                            } label: {
                                if settings.sortOrder == sort { Label(sort.label, systemImage: "checkmark") } else { Text(sort.label) }
                            }
                        }
                    }
                    Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    Button { importingPDF = true } label: { Label("Import PDF…", systemImage: "doc.badge.plus") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Options")

                Button { model.createNote() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        Text("New").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("New Note")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ note: Note) -> some View {
        let isOpen = model.openNoteID == note.id
        Button {
            if selecting {
                if selectedIDs.contains(note.id) { selectedIDs.remove(note.id) } else { selectedIDs.insert(note.id) }
            } else {
                model.open(note)
                if model.isSearching { focusSearchHit(note) }
            }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: selectedIDs.contains(note.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedIDs.contains(note.id) ? Theme.accent : Theme.textTertiary)
                }
                NoteRowContent(note: note, searchQuery: model.isSearching ? model.searchText : nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOpen && !selecting ? Theme.noteRowSelected : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .draggable(note.id.uuidString) {
            NoteRowContent(note: note, searchQuery: nil)
                .padding(8)
                .frame(width: 220)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.noteRowSelected))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = [note] } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button {
                renameText = note.title
                renaming = note
            } label: { Label("Rename", systemImage: "pencil") }
            Button { movingNotes = [note] } label: { Label("Move to…", systemImage: "folder") }
            Button { model.duplicate(note) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { pendingDelete = [note] } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// Search hit in a transcript → open the recording view at that line (PRD §7.6).
    private func focusSearchHit(_ note: Note) {
        let q = model.searchText
        guard !note.title.localizedCaseInsensitiveContains(q),
              let rec = note.orderedRecordings.first(where: { $0.transcriptText?.localizedCaseInsensitiveContains(q) == true }),
              let editor = model.editor else { return }
        editor.selectedRecordingID = rec.id
        if let t = TranscriptStore.load(noteID: note.id, recordingID: rec.id),
           let seg = t.segments.first(where: { $0.text.localizedCaseInsensitiveContains(q) }) {
            editor.focusSegmentStart = seg.start
        }
        editor.rail = .recordings
    }

    // MARK: Empty / selection

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if model.isSearching {
                Text(model.searchText.isEmpty ? "Search note titles and transcripts" : "No results")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No notes")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Tap New to start one.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var selectionBar: some View {
        let chosen = notes.filter { selectedIDs.contains($0.id) }
        return HStack {
            Button("Move") { movingNotes = chosen }
                .disabled(chosen.isEmpty)
            Spacer()
            Text(chosen.isEmpty ? "Select notes" : "\(chosen.count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Delete", role: .destructive) { pendingDelete = chosen }
                .disabled(chosen.isEmpty)
                .foregroundStyle(chosen.isEmpty ? Theme.textTertiary : Theme.recordRed)
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Thumbnail · title · date · mic glyph (PRD §6.3).
struct NoteRowContent: View {
    let note: Note
    let searchQuery: String?

    var body: some View {
        HStack(spacing: 11) {
            NoteThumbnail(note: note)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(note.modifiedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    if note.hasAudio {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Has recording")
                    }
                }
                if let snippet {
                    Text(snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Transcript context for a search hit.
    private var snippet: AttributedString? {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              !note.title.localizedCaseInsensitiveContains(q) else { return nil }
        for rec in note.orderedRecordings {
            guard let text = rec.transcriptText, let r = text.range(of: q, options: .caseInsensitive) else { continue }
            let start = text.index(r.lowerBound, offsetBy: -28, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            var s = AttributedString((start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : ""))
            if let hit = s.range(of: q, options: .caseInsensitive) {
                s[hit].foregroundColor = Theme.accent
                s[hit].font = .system(size: 11.5, weight: .semibold)
            }
            return s
        }
        return nil
    }
}

struct NoteThumbnail: View {
    let note: Note

    var body: some View {
        let version = note.thumbnailVersion
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: note.paper.color.hex))
            if let img = ThumbnailCache.shared.image(for: note.id, version: version) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54, alignment: .top)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// "Move to…" — pick a subject (or none).
struct MoveToSubjectSheet: View {
    let notes: [Note]
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Query(sort: \Subject.sortIndex) private var subjects: [Subject]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { onDone() }.foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(notes.count == 1 ? "Move Note" : "Move \(notes.count) Notes")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Cancel") {}.hidden()
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(subjects) { s in
                        moveRow(title: s.name, color: Color(hex: s.colorHex), current: notes.allSatisfy { $0.subject?.id == s.id }) {
                            notes.forEach { model.move($0, to: s) }
                            onDone()
                        }
                    }
                    moveRow(title: "No Subject", color: nil, current: notes.allSatisfy { $0.subject == nil }) {
                        notes.forEach { model.move($0, to: nil) }
                        onDone()
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .background(Theme.sidebar)
        .presentationDetents([.medium])
    }

    private func moveRow(title: String, color: Color?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let color { Circle().fill(color).frame(width: 12, height: 12) }
                else { Image(systemName: "tray").font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fieldBackground.opacity(0.5)))
        }
        .buttonStyle(PressableStyle())
    }
}
