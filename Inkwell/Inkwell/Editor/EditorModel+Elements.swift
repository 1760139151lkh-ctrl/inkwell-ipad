import Foundation
import PencilKit
import SwiftData
import UIKit

/// Text boxes and images (PRD §3 P1, §8.1 PageElement). Elements carry their own
/// `createdAt`, so they replay in sync with the audio just like strokes (§7.2).
extension EditorModel {
    // MARK: Snapshots

    var elementSnapshots: [ElementSnapshot] {
        note.elements.sorted { $0.createdAt < $1.createdAt }.map(snapshot)
    }

    func snapshot(_ e: PageElement) -> ElementSnapshot {
        ElementSnapshot(id: e.id, kind: e.kind, frame: e.frame, text: e.text ?? "",
                        fontSize: CGFloat(e.fontSize ?? Double(ElementSnapshot.defaultFontSize)),
                        isBold: e.isBold ?? false, colorHex: e.colorHex ?? "#1A1A1A",
                        image: e.kind == .image ? image(for: e) : nil, createdAt: e.createdAt)
    }

    func image(for e: PageElement) -> UIImage? {
        if let img = imageCache[e.id] { return img }
        guard let name = e.imageFileName,
              let img = UIImage(contentsOfFile: NoteFiles.imagesFolder(note.id).appendingPathComponent(name).path) else { return nil }
        imageCache[e.id] = img
        return img
    }

    var pdfDocument: CGPDFDocument? {
        note.pdfBackgroundFile.flatMap { CGPDFDocument(NoteFiles.folder(note.id).appendingPathComponent($0) as CFURL) }
    }

    func refreshElements() {
        canvas.setElements(elementSnapshots)
        updateIsEmpty(strokes: canvas.drawing.strokes.count)
    }

    func updateIsEmpty(strokes: Int) {
        isEmpty = strokes == 0 && note.elements.isEmpty && note.pdfBackgroundFile == nil
    }

    func element(_ id: UUID) -> PageElement? { note.elements.first { $0.id == id } }

    // MARK: Wiring

    func wireElements() {
        canvas.onElementFrameChanged = { [weak self] id, frame, final in
            guard let self, let e = self.element(id) else { return }
            if final {
                let old = e.frame
                if old != frame { self.registerFrameUndo(id: id, from: old, to: frame) }
                e.frame = frame
                self.touch()
                self.refreshElements()
            }
        }
        canvas.onElementDeleteRequested = { [weak self] id in self?.deleteElement(id) }
        canvas.onElementTextChanged = { [weak self] id, text, height in
            guard let self, let e = self.element(id) else { return }
            e.text = text
            var f = e.frame
            f.size.height = height
            e.frame = f
            self.touch(save: false)
        }
        canvas.onElementEditingEnded = { [weak self] id, text in
            guard let self else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.deleteElement(id, undoable: false)
            } else {
                self.refreshElements()
                self.touch()
            }
        }
    }

    /// Removes image files no element references (kept earlier for undo of a delete).
    func sweepOrphanImages() {
        let folder = NoteFiles.imagesFolder(note.id)
        let used = Set(note.elements.compactMap(\.imageFileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Taps

    /// Returns true if the tap was consumed by element handling.
    func handleElementTap(_ point: CGPoint) -> Bool {
        switch tools.current {
        case .text:
            if let id = canvas.elementHit(at: point), element(id)?.kind == .text {
                selectElement(id, editText: true)
            } else if selectedElementID != nil {
                deselectElement()
            } else {
                addTextBox(at: point)
            }
            return true
        case .lasso:
            if let id = canvas.elementHit(at: point) {
                selectElement(id, editText: false)
                return true
            }
            if selectedElementID != nil { deselectElement(); return true }
            return false
        default:
            if selectedElementID != nil { deselectElement(); return true }
            return false
        }
    }

    func selectElement(_ id: UUID, editText: Bool) {
        selectedElementID = id
        canvas.select(elementID: id, editText: editText)
    }

    func deselectElement() {
        guard selectedElementID != nil else { return }
        selectedElementID = nil
        canvas.select(elementID: nil)
        refreshElements()
    }

    // MARK: Create

    func addTextBox(at point: CGPoint) {
        let cfg = tools.text
        let width: CGFloat = min(300, note.paper.pageSize.width - point.x - 12)
        let font = ElementSnapshot.serif(cfg.fontSize, bold: cfg.bold)
        let height = ElementSnapshot.textHeight("", width: max(80, width), font: font)
        let e = PageElement(kind: .text, frame: CGRect(x: point.x - 6, y: point.y - height / 2, width: max(80, width), height: height))
        e.text = ""
        e.fontSize = Double(cfg.fontSize)
        e.isBold = cfg.bold
        e.colorHex = cfg.colorHex
        insert(e)
        selectElement(e.id, editText: true)
    }

    /// Photos (PRD §3 P1): placed centered on the visible page, up to 300 pt wide.
    func addImage(data: Data) {
        guard let source = UIImage(data: data) else { return }
        let image = source.downscaled(maxPixel: 2400)
        let e = PageElement(kind: .image, frame: .zero)
        let name = "\(e.id.uuidString).jpg"
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        try? jpeg.write(to: NoteFiles.imagesFolder(note.id).appendingPathComponent(name), options: .atomic)
        e.imageFileName = name
        let page = PageGeometry(paper: note.paper).pageRect(visiblePage)
        let w = min(300, page.width - 80)
        let h = w * image.size.height / max(image.size.width, 1)
        e.frame = CGRect(x: page.midX - w / 2, y: page.minY + max(60, min(page.height - h - 40, page.height * 0.25)), width: w, height: h)
        imageCache[e.id] = image
        if tools.current != .lasso {
            tools.select(.lasso)
            applyTool()
        }
        insert(e)
        selectElement(e.id, editText: false)
    }

    private func insert(_ e: PageElement) {
        context.insert(e)
        note.elements.append(e)
        e.note = note
        refreshElements()
        touch()
        let id = e.id
        canvas.canvas.undoManager?.registerUndo(withTarget: self) { model in
            model.deleteElement(id, undoable: false)
        }
        canvas.canvas.undoManager?.setActionName("Add")
    }

    // MARK: Delete

    func deleteElement(_ id: UUID, undoable: Bool = true) {
        guard let e = element(id) else { return }
        let snap = snapshot(e)
        let fileName = e.imageFileName
        if selectedElementID == id {
            selectedElementID = nil
            canvas.select(elementID: nil)
        }
        note.elements.removeAll { $0.id == id }
        context.delete(e)
        refreshElements()
        touch()
        if undoable {
            canvas.canvas.undoManager?.registerUndo(withTarget: self) { model in
                model.restoreElement(snap, fileName: fileName)
            }
            canvas.canvas.undoManager?.setActionName("Delete")
        } else if let fileName {
            try? FileManager.default.removeItem(at: NoteFiles.imagesFolder(note.id).appendingPathComponent(fileName))
        }
    }

    private func restoreElement(_ s: ElementSnapshot, fileName: String?) {
        let e = PageElement(kind: s.kind, frame: s.frame)
        e.id = s.id
        e.createdAt = s.createdAt
        e.text = s.text
        e.fontSize = Double(s.fontSize)
        e.isBold = s.isBold
        e.colorHex = s.colorHex
        e.imageFileName = fileName
        insert(e)
    }

    private func registerFrameUndo(id: UUID, from old: CGRect, to new: CGRect) {
        canvas.canvas.undoManager?.registerUndo(withTarget: self) { model in
            guard let e = model.element(id) else { return }
            model.registerFrameUndo(id: id, from: new, to: old)
            e.frame = old
            model.refreshElements()
            if model.selectedElementID == id { model.canvas.select(elementID: id) }
            model.touch()
        }
        canvas.canvas.undoManager?.setActionName("Move")
    }

    // MARK: Text style (sub-bar)

    /// Applies the Text tool's current style to the selected text box, if any.
    func applyTextStyleToSelection() {
        guard let id = selectedElementID, let e = element(id), e.kind == .text else { return }
        let cfg = tools.text
        e.fontSize = Double(cfg.fontSize)
        e.isBold = cfg.bold
        e.colorHex = cfg.colorHex
        let font = ElementSnapshot.serif(cfg.fontSize, bold: cfg.bold)
        var f = e.frame
        f.size.height = ElementSnapshot.textHeight(e.text ?? "", width: f.width, font: font)
        e.frame = f
        refreshElements()
        touch()
    }

    func touch(save: Bool = true) {
        note.modifiedAt = Date()
        if save { scheduleElementSave() }
    }

    private func scheduleElementSave() {
        try? context.save()
        scheduleSave()
    }

    // MARK: PDF import into this note (empty note footer "Import")

    func importPDF(from url: URL) {
        guard PDFImport.attach(url, to: note) else { return }
        canvas.setPaper(note.paper)
        canvas.setPDF(url: NoteFiles.folder(note.id).appendingPathComponent(note.pdfBackgroundFile ?? ""))
        setPageCount(max(pageCount, note.pageCount))
        updateIsEmpty(strokes: canvas.drawing.strokes.count)
        flush()
    }
}

enum PDFImport {
    /// Copies a PDF into the note folder as its page backgrounds. Returns false if unreadable.
    @MainActor
    static func attach(_ url: URL, to note: Note) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return false }
        let dest = NoteFiles.folder(note.id).appendingPathComponent("background.pdf")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return false }
        note.pdfBackgroundFile = "background.pdf"
        note.pageCount = max(note.pageCount, doc.numberOfPages)
        if let first = doc.page(at: 1) {
            let box = PDFBackground.displaySize(of: first)
            var p = note.paper
            p.landscape = box.width > box.height
            p.style = .blank
            note.paper = p
        }
        note.modifiedAt = Date()
        return true
    }
}

extension UIImage {
    func downscaled(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height) * scale
        guard longest > maxPixel else { return self }
        let factor = maxPixel / longest
        let newSize = CGSize(width: size.width * scale * factor, height: size.height * scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
