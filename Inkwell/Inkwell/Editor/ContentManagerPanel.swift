import SwiftUI
import PencilKit

/// Content manager (PRD §6.8): page thumbnails, bookmarks, jump to a page, delete pages.
struct ContentManagerPanel: View {
    @Bindable var editor: EditorModel
    @State private var bookmarkedOnly = false
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var confirmDelete = false
    @State private var thumbs: [Int: UIImage] = [:]

    private var pages: [Int] {
        let all = Array(0..<editor.pageCount)
        return bookmarkedOnly ? all.filter { editor.note.bookmarkedPages.contains($0) } : all
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button { bookmarkedOnly = false } label: { Label("All Pages", systemImage: bookmarkedOnly ? "" : "checkmark") }
                    Button { bookmarkedOnly = true } label: { Label("Bookmarked", systemImage: bookmarkedOnly ? "checkmark" : "") }
                } label: {
                    HStack(spacing: 4) {
                        Text(bookmarkedOnly ? "Bookmarked" : "All Pages")
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    selected = []
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(pages, id: \.self) { i in
                        pageCell(i)
                    }
                    if pages.isEmpty {
                        Text("No bookmarked pages")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical, 12)
            }

            if selecting {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text(selected.isEmpty ? "Delete" : "Delete \(selected.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(selected.isEmpty || selected.count >= editor.pageCount || selectsPDFPage)
                .foregroundStyle(selected.isEmpty ? Theme.textTertiary : Theme.recordRed)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                if selectsPDFPage {
                    Text("Pages from an imported PDF can’t be deleted.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1) }
        .task(id: editor.note.thumbnailVersion) { renderThumbs() }
        .confirmationDialog("Delete \(selected.count == 1 ? "this page" : "\(selected.count) pages")?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                PageOperations.deletePages(selected, editor: editor)
                selected = []
                selecting = false
                renderThumbs()
            }
        }
    }

    private func pageCell(_ i: Int) -> some View {
        let bookmarked = editor.note.bookmarkedPages.contains(i)
        let isCurrent = editor.visiblePage == i
        let aspect = editor.note.paper.pageSize.width / editor.note.paper.pageSize.height
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbs[i] {
                        Image(uiImage: img).resizable()
                    } else {
                        Rectangle().fill(Color(hex: editor.note.paper.color.hex))
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(width: 128)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selecting ? (selected.contains(i) ? Theme.accent : .clear) : (isCurrent ? Theme.accent : .clear), lineWidth: 2.5)
                        .padding(-4)
                )

                Button {
                    if bookmarked { editor.note.bookmarkedPages.removeAll { $0 == i } } else { editor.note.bookmarkedPages.append(i) }
                    editor.note.modifiedAt = Date()
                    BackupEngine.shared.noteChanged()
                } label: {
                    Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(bookmarked ? Theme.recordRed : Color.gray.opacity(0.55))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(bookmarked ? "Remove bookmark" : "Bookmark page")
            }
            Text("\(i + 1)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
            } else {
                editor.goToPage(i)
            }
        }
    }

    /// PDF pages are tied to note pages by index, so they can't be removed individually.
    private var selectsPDFPage: Bool {
        guard let pdf = editor.pdfDocument else { return false }
        return selected.contains { $0 < pdf.numberOfPages }
    }

    /// Renders page thumbnails off the main thread (a long PDF must not freeze the UI).
    private func renderThumbs() {
        let drawing = editor.canvas.drawing
        let paper = editor.note.paper
        let pdfURL = editor.note.pdfBackgroundFile.map { NoteFiles.folder(editor.note.id).appendingPathComponent($0) }
        let elements = editor.elementSnapshots
        let count = editor.pageCount
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> [Int: UIImage] in
                let pdf = pdfURL.flatMap { CGPDFDocument($0 as CFURL) }
                var out: [Int: UIImage] = [:]
                for i in 0..<count {
                    out[i] = ThumbnailRenderer.image(drawing: drawing, paper: paper, pageIndex: i, width: 256,
                                                     pdf: pdf, elements: elements)
                }
                return out
            }.value
            thumbs = rendered
        }
    }
}

enum PageOperations {
    /// Removes pages: strokes on them are deleted, strokes below shift up.
    @MainActor
    static func deletePages(_ pages: Set<Int>, editor: EditorModel) {
        guard !pages.isEmpty, pages.count < editor.pageCount else { return }
        let geo = PageGeometry(paper: editor.note.paper)
        var strokes: [PKStroke] = []
        for var stroke in editor.canvas.drawing.strokes {
            let page = geo.pageIndex(forY: stroke.renderBounds.midY)
            if pages.contains(page) { continue }
            let removedAbove = pages.filter { $0 < page }.count
            if removedAbove > 0 {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: -CGFloat(removedAbove) * geo.pitch))
            }
            strokes.append(stroke)
        }
        editor.canvas.replaceDrawing(PKDrawing(strokes: strokes))
        // Elements follow the same rule as strokes.
        for e in editor.note.elements {
            let page = geo.pageIndex(forY: e.frame.midY)
            if pages.contains(page) {
                editor.deleteElement(e.id, undoable: false)
            } else {
                let removedAbove = pages.filter { $0 < page }.count
                if removedAbove > 0 { e.frame = e.frame.offsetBy(dx: 0, dy: -CGFloat(removedAbove) * geo.pitch) }
            }
        }
        editor.refreshElements()
        editor.note.modifiedAt = Date()
        editor.note.bookmarkedPages = editor.note.bookmarkedPages.compactMap { p in
            pages.contains(p) ? nil : p - pages.filter { $0 < p }.count
        }
        editor.setPageCount(editor.pageCount - pages.count)
        editor.flush()
    }
}

/// Share PDF (PRD §6.4, P1): paper + ink, one PDF page per note page.
enum PDFExporter {
    @MainActor
    static func export(note: Note, drawing: PKDrawing, pdf: CGPDFDocument? = nil, elements: [ElementSnapshot] = []) -> URL? {
        let paper = note.paper
        let geo = PageGeometry(paper: paper)
        let safeTitle = note.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle).pdf")
        let bounds = CGRect(origin: .zero, size: paper.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let style: UIUserInterfaceStyle = paper.color.isDark ? .dark : .light
        do {
            try renderer.writePDF(to: url) { ctx in
                for i in 0..<note.pageCount {
                    ctx.beginPage()
                    PageComposer.drawBackground(pageIndex: i, paper: paper, pdf: pdf, elements: elements,
                                                pageRect: geo.pageRect(i), context: ctx.cgContext)
                    var ink = UIImage()
                    UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                        ink = drawing.image(from: geo.pageRect(i), scale: 3)
                    }
                    ink.draw(in: bounds)
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
