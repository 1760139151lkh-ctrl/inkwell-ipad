import Foundation
import PencilKit
import UIKit
import Vision

/// Packages a note for a coding/chat agent (PRD §10, Phase 3): handwriting PDF + page images,
/// handwriting read on-device, and "moments" — clusters of ink paired with when they were
/// written — so the agent can line up "while Pat wrote this, the call was saying that".
nonisolated enum HandoffBuilder {
    struct Moment: Sendable {
        var page: Int
        var bbox: CGRect          // page coordinates
        var tStart: Double?       // note-timeline seconds
        var tEnd: Double?
        var text: String
    }

    struct Package: Sendable {
        var folder: URL           // this run's export folder; delete after upload
        var pdfURL: URL
        var pageImages: [URL]     // 1-based page order
        var pageText: [String]
        var moments: [Moment]
    }

    /// The server accepts at most 5000 moments; a note that large gets its first ones.
    static let maxMoments = 2000

    /// Everything here is CPU work; run it off the main thread. Pages are handled one at a
    /// time so a long note never holds more than one full-resolution page in memory.
    static func build(noteID: UUID, title: String, paper: Paper, pageCount: Int, drawing: PKDrawing,
                      pdf: CGPDFDocument?, elements: [ElementSnapshot], timeline: NoteTimeline) async throws -> Package {
        // Each run writes to its own folder, so a cancelled earlier run can't clobber this one.
        let root = NoteFiles.folder(noteID).appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let geo = PageGeometry(paper: paper)
        let pages = max(1, pageCount)

        let clusters = Array(cluster(drawing.strokes, geometry: geo, timeline: timeline).prefix(maxMoments))
        let clustersByPage = Dictionary(grouping: clusters.indices, by: { clusters[$0].page })
        var texts = [String](repeating: "", count: clusters.count)

        var images: [URL] = []
        var pageText: [String] = []
        for i in 0..<pages {
            try Task.checkCancellation()
            let pageRect = geo.pageRect(i)
            let url = folder.appendingPathComponent("page-\(i + 1).png")
            try autoreleasepool {
                // 1. The page at OCR-friendly resolution.
                let img = ThumbnailRenderer.image(drawing: drawing, paper: paper, pageIndex: i, width: paper.pageSize.width * 2.5,
                                                  pdf: pdf, elements: elements)
                try img.pngData()?.write(to: url, options: .atomic)
                guard let cg = img.cgImage else { pageText.append(""); return }

                // 2. Read the page once; each moment takes the lines its ink overlaps.
                let lines = recognizeLines(cg, pageSize: paper.pageSize)
                pageText.append(lines.map(\.text).joined(separator: "\n"))
                for ci in clustersByPage[i] ?? [] {
                    let box = clusters[ci].bounds.offsetBy(dx: -pageRect.minX, dy: -pageRect.minY)
                    let hits = lines.filter { overlaps($0.rect, box) }
                    // A mark Vision didn't pick up at page scale: try its region alone.
                    texts[ci] = hits.isEmpty ? recognizeLines(cg, pageSize: paper.pageSize, region: box.insetBy(dx: -6, dy: -6))
                                                   .map(\.text).joined(separator: "\n")
                                             : hits.map(\.text).joined(separator: "\n")
                }
            }
            images.append(url)
        }
        try Task.checkCancellation()
        let pdfURL = folder.appendingPathComponent("notes.pdf")
        try renderPDF(to: pdfURL, paper: paper, pageCount: pages, drawing: drawing, pdf: pdf, elements: elements, title: title)

        // 3. Moments: ink grouped into lines/thoughts, each read and timed. bbox is page-local points.
        let moments = clusters.indices.map { ci in
            let c = clusters[ci]
            return Moment(page: c.page, bbox: c.bounds.offsetBy(dx: -geo.pageRect(c.page).minX, dy: -geo.pageRect(c.page).minY),
                          tStart: c.tStart, tEnd: c.tEnd, text: texts[ci])
        }
        return Package(folder: folder, pdfURL: pdfURL, pageImages: images, pageText: pageText, moments: moments)
    }

    /// A recognized line belongs to a moment when most of the smaller of the two boxes overlaps.
    static func overlaps(_ line: CGRect, _ ink: CGRect) -> Bool {
        let i = line.intersection(ink.insetBy(dx: -4, dy: -4))
        guard !i.isNull else { return false }
        let smaller = min(line.width * line.height, ink.width * ink.height)
        return smaller > 0 && i.width * i.height >= 0.5 * smaller
    }

    // MARK: Clustering

    struct Cluster { var page: Int; var bounds: CGRect; var tStart: Double?; var tEnd: Double?; var lastDate: Date }

    /// Strokes in writing order; a new cluster starts after a pause (> 2.5 s) or when the pen
    /// jumps to a different line / region of the page.
    static func cluster(_ strokes: [PKStroke], geometry: PageGeometry, timeline: NoteTimeline) -> [Cluster] {
        let ordered = strokes.sorted { $0.path.creationDate < $1.path.creationDate }
        var out: [Cluster] = []
        for s in ordered {
            let b = s.renderBounds
            guard !b.isNull, b.width > 0 || b.height > 0 else { continue }
            let date = s.path.creationDate
            let page = geometry.pageIndex(forY: b.midY)
            let t = timeline.timelineTime(of: date)
            if var last = out.last, last.page == page,
               date.timeIntervalSince(last.lastDate) < 2.5,
               b.midY > last.bounds.minY - 30, b.midY < last.bounds.maxY + 30 {
                last.bounds = last.bounds.union(b)
                last.lastDate = date
                if let t { last.tStart = min(last.tStart ?? t, t); last.tEnd = max(last.tEnd ?? t, t) }
                out[out.count - 1] = last
            } else {
                out.append(Cluster(page: page, bounds: b, tStart: t, tEnd: t, lastDate: date))
            }
        }
        // Drop specks (a dot or a single tiny mark) that carry no content on their own.
        return out.filter { $0.bounds.width > 14 || $0.bounds.height > 14 }
    }

    // MARK: Handwriting recognition (on-device Vision)

    struct Line { var text: String; var rect: CGRect }   // rect in page points, top-left origin

    static func recognizeLines(_ cg: CGImage, pageSize: CGSize, region: CGRect? = nil) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supportedLanguages.contains($0) }
        if !preferredLanguages.isEmpty { request.recognitionLanguages = preferredLanguages }
        request.automaticallyDetectsLanguage = true
        if let region {
            // Vision's region of interest is normalized with a bottom-left origin.
            let r = region.intersection(CGRect(origin: .zero, size: pageSize))
            guard !r.isNull, r.width > 4, r.height > 4 else { return [] }
            request.regionOfInterest = CGRect(x: r.minX / pageSize.width, y: 1 - r.maxY / pageSize.height,
                                              width: r.width / pageSize.width, height: r.height / pageSize.height)
        }
        do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { return [] }
        // Bounding boxes are normalized to the full image even with a region of interest.
        let lines: [Line] = (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox
            return Line(text: text, rect: CGRect(x: b.minX * pageSize.width, y: (1 - b.maxY) * pageSize.height,
                                                 width: b.width * pageSize.width, height: b.height * pageSize.height))
        }
        // Top-to-bottom, then left-to-right.
        return lines.sorted { abs($0.rect.midY - $1.rect.midY) > 8 ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
    }

    // MARK: PDF

    static func renderPDF(to url: URL, paper: Paper, pageCount: Int, drawing: PKDrawing, pdf: CGPDFDocument?,
                          elements: [ElementSnapshot], title: String) throws {
        let geo = PageGeometry(paper: paper)
        let bounds = CGRect(origin: .zero, size: paper.pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Inkwell"]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let style: UIUserInterfaceStyle = paper.color.isDark ? .dark : .light
        try renderer.writePDF(to: url) { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                PageComposer.drawBackground(pageIndex: i, paper: paper, pdf: pdf, elements: elements,
                                            pageRect: geo.pageRect(i), context: ctx.cgContext)
                autoreleasepool {
                    var ink = UIImage()
                    UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                        ink = drawing.image(from: geo.pageRect(i), scale: 3)
                    }
                    ink.draw(in: bounds)
                }
            }
        }
    }
}
