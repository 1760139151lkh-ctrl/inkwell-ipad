import Foundation
import PencilKit
import UIKit

/// On-disk layout, one folder per note (PRD §8.2):
///
///     Notes/<noteID>/
///       drawing.pkdrawing
///       thumb.png
///       audio/<recordingID>.m4a      (+ <recordingID>.caf while recording / before transcode)
///       transcript/<recordingID>.json
nonisolated enum NoteFiles {
    /// The current account's notes folder (see StorageScope).
    static var root: URL {
        let url = StorageScope.current.notesRoot
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ noteID: UUID) -> URL {
        let url = root.appendingPathComponent(noteID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func drawingURL(_ noteID: UUID) -> URL { folder(noteID).appendingPathComponent("drawing.pkdrawing") }
    static func thumbURL(_ noteID: UUID) -> URL { folder(noteID).appendingPathComponent("thumb.png") }

    static func audioFolder(_ noteID: UUID) -> URL {
        let url = folder(noteID).appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func imagesFolder(_ noteID: UUID) -> URL {
        let url = folder(noteID).appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func transcriptFolder(_ noteID: UUID) -> URL {
        let url = folder(noteID).appendingPathComponent("transcript", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Final compressed audio.
    static func audioURL(noteID: UUID, recordingID: UUID) -> URL {
        audioFolder(noteID).appendingPathComponent("\(recordingID.uuidString).m4a")
    }

    /// Crash-safe PCM capture file, written while recording and transcoded to .m4a on stop.
    static func captureURL(noteID: UUID, recordingID: UUID) -> URL {
        audioFolder(noteID).appendingPathComponent("\(recordingID.uuidString).caf")
    }

    /// The best playable file for a recording: the .m4a once transcoded, else the capture file.
    static func playableAudioURL(noteID: UUID, recordingID: UUID) -> URL? {
        let m4a = audioURL(noteID: noteID, recordingID: recordingID)
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }
        let caf = captureURL(noteID: noteID, recordingID: recordingID)
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        return nil
    }

    static func transcriptURL(noteID: UUID, recordingID: UUID) -> URL {
        transcriptFolder(noteID).appendingPathComponent("\(recordingID.uuidString).json")
    }

    static func deleteNoteFolder(_ noteID: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(noteID.uuidString, isDirectory: true))
    }

    static func deleteRecordingFiles(noteID: UUID, recordingID: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: audioURL(noteID: noteID, recordingID: recordingID))
        try? fm.removeItem(at: captureURL(noteID: noteID, recordingID: recordingID))
        try? fm.removeItem(at: transcriptURL(noteID: noteID, recordingID: recordingID))
    }

    static func copyNoteFolder(from source: UUID, to dest: UUID) {
        let fm = FileManager.default
        let src = folder(source)
        let dst = root.appendingPathComponent(dest.uuidString, isDirectory: true)
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
        // Recordings are not duplicated (new recording IDs would be needed); keep ink + thumb only.
        try? fm.removeItem(at: dst.appendingPathComponent("audio"))
        try? fm.removeItem(at: dst.appendingPathComponent("transcript"))
    }

    static var totalBytesUsed: Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Drawing persistence

nonisolated enum DrawingStore {
    static func load(_ noteID: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: NoteFiles.drawingURL(noteID)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    static func save(_ drawing: PKDrawing, noteID: UUID) {
        let data = drawing.dataRepresentation()
        try? data.write(to: NoteFiles.drawingURL(noteID), options: .atomic)
    }
}

// MARK: - Thumbnails

nonisolated enum ThumbnailRenderer {
    static let pixelWidth: CGFloat = 200

    /// Renders page 1 (paper + PDF background + elements + ink) to `thumb.png`.
    static func render(drawing: PKDrawing, paper: Paper, noteID: UUID,
                       pdf: CGPDFDocument? = nil, elements: [ElementSnapshot] = []) {
        let image = image(drawing: drawing, paper: paper, pageIndex: 0, width: pixelWidth, pdf: pdf, elements: elements)
        if let png = image.pngData() {
            try? png.write(to: NoteFiles.thumbURL(noteID), options: .atomic)
        }
    }

    static func image(drawing: PKDrawing, paper: Paper, pageIndex: Int, width: CGFloat,
                      pdf: CGPDFDocument? = nil, elements: [ElementSnapshot] = []) -> UIImage {
        let pageSize = paper.pageSize
        let scale = width / pageSize.width
        let size = CGSize(width: width, height: pageSize.height * scale)
        let pageRect = PageGeometry(paper: paper).pageRect(pageIndex)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard   // 8-bit: half the memory and PNG size of extended range
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            PageComposer.drawBackground(pageIndex: pageIndex, paper: paper, pdf: pdf, elements: elements,
                                        pageRect: pageRect, context: cg)
            cg.restoreGState()
            // PencilKit adapts ink to the interface style; render in the paper's style.
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: paper.color.isDark ? .dark : .light).performAsCurrent {
                // 2× supersampling for small thumbnails; capped so full-size exports stay within memory.
                ink = drawing.image(from: pageRect, scale: min(max(1, 2 * scale), max(scale, 3)))
            }
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for noteID: UUID, version: Int) -> UIImage? {
        let key = "\(noteID.uuidString)-\(version)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = UIImage(contentsOfFile: NoteFiles.thumbURL(noteID).path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

}

/// Paper + imported PDF page + elements for one page, in a UIKit (y-down) context whose
/// origin is the page's top-left. Ink is drawn separately on top.
nonisolated enum PageComposer {
    static func drawBackground(pageIndex: Int, paper: Paper, pdf: CGPDFDocument?, elements: [ElementSnapshot],
                               pageRect: CGRect, context cg: CGContext) {
        let local = CGRect(origin: .zero, size: pageRect.size)
        PaperRenderer.draw(paper: paper, in: local, context: cg)
        if let pdf, pageIndex + 1 <= pdf.numberOfPages, let page = pdf.page(at: pageIndex + 1) {
            PDFBackground.draw(page: page, in: local, context: cg, flipped: true)
        }
        UIGraphicsPushContext(cg)
        for e in elements where e.frame.intersects(pageRect) {
            e.draw(offsetY: pageRect.minY)
        }
        UIGraphicsPopContext()
    }
}
