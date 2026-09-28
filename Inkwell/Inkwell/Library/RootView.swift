import SwiftUI
import SwiftData

/// Library (sidebar + note list) beside the note editor (PRD §5). The Library toggle
/// collapses the first two columns so the note goes full-screen for writing.
struct RootView: View {
    @Environment(AppModel.self) private var model

    static let sidebarWidth: CGFloat = 236
    static let noteListWidth: CGFloat = 232

    /// Narrower than this and the library slides over the note instead of pushing it.
    static let minEditorWidth: CGFloat = 700

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let libraryWidth = Self.sidebarWidth + Self.noteListWidth
            let overlay = geo.size.width - libraryWidth < Self.minEditorWidth
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if model.libraryVisible && !overlay {
                        library
                            .transition(.move(edge: .leading))
                    }
                    editorColumn
                }
                if overlay && model.libraryVisible {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { model.libraryVisible = false }
                        .transition(.opacity)
                    library
                        .shadow(color: .black.opacity(0.45), radius: 24, x: 6)
                        .transition(.move(edge: .leading))
                }
            }
            .onChange(of: model.openNoteID) { _, _ in
                // In slide-over mode, picking a note puts it in front.
                if overlay && model.editor != nil && !model.isSearching { model.libraryVisible = false }
            }
            .onAppear { model.libraryIsOverlay = overlay }
            .onChange(of: overlay) { _, o in model.libraryIsOverlay = o }
        }
        .background(Theme.editorChrome)
        .animation(.snappy(duration: 0.28), value: model.libraryVisible)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environment(model)
        }
    }

    private var library: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Self.sidebarWidth)
            NoteListView()
                .frame(width: Self.noteListWidth)
        }
    }

    private var editorColumn: some View {
        Group {
            if let editor = model.editor {
                NoteEditorView(editor: editor)
                    .id(editor.note.id)
            } else {
                EmptyEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown only when there are no notes yet (or the open note was deleted).
struct EmptyEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ChromePill {
                    ChromeIconButton(systemName: "sidebar.left", label: "Library") {
                        model.libraryVisible.toggle()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            ZStack {
                Theme.canvasBackdrop
                VStack(spacing: 14) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No note open")
                        .font(Theme.serif(22, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        model.createNote()
                    } label: {
                        Label("New Note", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .background(Theme.editorChrome)
    }
}
