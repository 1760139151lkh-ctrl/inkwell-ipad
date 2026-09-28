import SwiftUI
import SwiftData

/// Library sidebar (PRD §6.2): Settings · Search · Notes · Subjects.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Subject.sortIndex) private var subjects: [Subject]
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil }) private var liveNotes: [Note]
    @Query(sort: \SubjectDivider.sortIndex) private var dividers: [SubjectDivider]

    @State private var editingSubject: SubjectEditorTarget?
    @State private var subjectToDelete: Subject?
    @State private var dividerNameTarget: DividerNameTarget?
    @State private var dividerName = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Settings
            HStack {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Settings")
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 56)

            // Search
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("", text: $model.searchText, prompt: Text("Search").foregroundStyle(Theme.textTertiary))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fieldBackground.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))

                if model.isSearching {
                    Button("Cancel") {
                        model.searchText = ""
                        searchFocused = false
                        model.isSearching = false
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .animation(.snappy(duration: 0.2), value: model.isSearching)
            .onChange(of: searchFocused) { _, focused in
                if focused { model.isSearching = true }
            }
            .onChange(of: model.searchText) { _, text in
                if !text.isEmpty { model.isSearching = true }
            }

            // Notes (All)
            SidebarRow(title: "Notes", icon: .symbol("square.and.pencil"), count: liveNotes.count,
                       isSelected: model.selection == .all && !model.isSearching) {
                model.selection = .all
                model.isSearching = false
                searchFocused = false
            }
            .padding(.top, 14)
            .padding(.horizontal, 8)

            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, 14).padding(.vertical, 12)

            // Subjects
            HStack {
                Text("Subjects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    Button { editingSubject = .new } label: { Label("New Subject", systemImage: "circle.fill") }
                    Button {
                        dividerName = ""
                        dividerNameTarget = .new
                    } label: { Label("New Divider", systemImage: "rectangle.split.1x2") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                } primaryAction: {
                    editingSubject = .new
                }
                .accessibilityLabel("New Subject")
                .accessibilityHint("Long-press for New Divider")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)

            List {
                // Subjects without a divider first, then each divider's group (PRD §6.2, P1).
                ForEach(subjects.filter { $0.divider == nil }) { subject in
                    subjectRow(subject)
                }
                .onMove { moveSubjects(in: nil, from: $0, to: $1) }

                ForEach(dividers) { divider in
                    DividerRow(divider: divider) {
                        withAnimation(.snappy(duration: 0.2)) { divider.isCollapsed.toggle() }
                        try? context.save()
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button {
                            dividerName = divider.name
                            dividerNameTarget = .rename(divider)
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { deleteDivider(divider) } label: { Label("Delete Divider", systemImage: "trash") }
                    }
                    if !divider.isCollapsed {
                        ForEach(subjects.filter { $0.divider?.id == divider.id }) { subject in
                            subjectRow(subject)
                        }
                        .onMove { moveSubjects(in: divider, from: $0, to: $1) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 38)

            RecordingPill()
                .padding(12)
        }
        .background(Theme.sidebar)
        .onChange(of: model.requestNewSubject, initial: true) { _, requested in
            if requested {
                model.requestNewSubject = false
                editingSubject = .new
            }
        }
        .sheet(item: $editingSubject) { target in
            SubjectEditorSheet(target: target)
        }
        .alert(dividerNameTarget?.title ?? "", isPresented: Binding(get: { dividerNameTarget != nil },
                                                                    set: { if !$0 { dividerNameTarget = nil } })) {
            TextField("Divider name", text: $dividerName)
            Button("Cancel", role: .cancel) { dividerNameTarget = nil }
            Button("Save") {
                commitDividerName()
                dividerNameTarget = nil
            }
        }
        .alert("Delete “\(subjectToDelete?.name ?? "")”?", isPresented: Binding(
            get: { subjectToDelete != nil }, set: { if !$0 { subjectToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let s = subjectToDelete { model.deleteSubject(s) }
                subjectToDelete = nil
            }
            Button("Cancel", role: .cancel) { subjectToDelete = nil }
        } message: {
            Text("Its notes won’t be deleted. They’ll stay in Notes, without a subject.")
        }
    }

    @ViewBuilder
    private func subjectRow(_ subject: Subject) -> some View {
        SidebarRow(title: subject.name, icon: .dot(Color(hex: subject.colorHex)),
                   count: subject.liveNotes.count,
                   isSelected: model.selection == .subject(subject.id) && !model.isSearching) {
            model.selection = .subject(subject.id)
            model.isSearching = false
            searchFocused = false
        }
        .listRowInsets(EdgeInsets(top: 1, leading: subject.divider == nil ? 8 : 18, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .dropDestination(for: String.self) { items, _ in
            moveNotes(items, to: subject)
        }
        .contextMenu {
            Button { editingSubject = .rename(subject) } label: { Label("Rename", systemImage: "pencil") }
            Button { editingSubject = .recolor(subject) } label: { Label("Change Color", systemImage: "paintpalette") }
            if !dividers.isEmpty {
                Menu {
                    Button { setDivider(subject, nil) } label: {
                        if subject.divider == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    ForEach(dividers) { d in
                        Button { setDivider(subject, d) } label: {
                            if subject.divider?.id == d.id { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                        }
                    }
                } label: { Label("Move to Divider", systemImage: "rectangle.split.1x2") }
            }
            Divider()
            Button(role: .destructive) { subjectToDelete = subject } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// Reorders subjects within one group (ungrouped, or one divider).
    private func moveSubjects(in divider: SubjectDivider?, from source: IndexSet, to destination: Int) {
        var group = subjects.filter { $0.divider?.id == divider?.id }
        group.move(fromOffsets: source, toOffset: destination)
        let others = subjects.filter { $0.divider?.id != divider?.id }
        for (i, s) in (group + others).enumerated() { s.sortIndex = i }
        try? context.save()
    }

    private func setDivider(_ subject: Subject, _ divider: SubjectDivider?) {
        subject.divider = divider
        try? context.save()
    }

    private func deleteDivider(_ divider: SubjectDivider) {
        for s in subjects where s.divider?.id == divider.id { s.divider = nil }
        context.delete(divider)
        try? context.save()
    }

    private func commitDividerName() {
        let name = dividerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch dividerNameTarget {
        case .new:
            let d = SubjectDivider(name: name, sortIndex: dividers.count)
            context.insert(d)
        case .rename(let d):
            d.name = name
        case nil:
            break
        }
        try? context.save()
    }

    private func moveNotes(_ ids: [String], to subject: Subject) -> Bool {
        var moved = false
        for idString in ids {
            guard let id = UUID(uuidString: idString),
                  let note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
            else { continue }
            model.move(note, to: subject)
            moved = true
        }
        return moved
    }
}

struct SidebarRow: View {
    enum Icon { case symbol(String), dot(Color) }

    let title: String
    let icon: Icon
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20)
                case .dot(let color):
                    Circle().fill(color).frame(width: 11, height: 11)
                        .frame(width: 20)
                }
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Count on the selected row only, as in Notability (PRD §6.2).
                if isSelected {
                    Text("\(count)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.rowSelected : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// "● REC 12:48" — shown in the Library while any note is recording (PRD §6.6).
struct RecordingPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    private var recorder: AudioRecorder { .shared }

    var body: some View {
        if recorder.isRecording, let noteID = recorder.noteID {
            Button {
                if let note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).first {
                    model.open(note)
                    model.editor?.rail = .recordings
                }
            } label: {
                HStack(spacing: 8) {
                    PulsingDot(color: Theme.recordRed, size: 8)
                    Text("REC")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.recordRed)
                    Text(recorder.elapsed.clockString)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Capsule().fill(Theme.recordRed.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Theme.recordRed.opacity(0.35)))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Recording in progress. Go to note.")
        }
    }
}

struct PulsingDot: View {
    var color: Color
    var size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}


enum DividerNameTarget {
    case new
    case rename(SubjectDivider)
    var title: String {
        switch self {
        case .new: "New Divider"
        case .rename: "Rename Divider"
        }
    }
}

/// Collapsible divider header in the sidebar.
struct DividerRow: View {
    let divider: SubjectDivider
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(divider.name.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(divider.isCollapsed ? -90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(divider.name) divider, \(divider.isCollapsed ? "collapsed" : "expanded")")
    }
}
