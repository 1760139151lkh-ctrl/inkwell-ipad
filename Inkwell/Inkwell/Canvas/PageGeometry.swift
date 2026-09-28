import CoreGraphics
import UIKit

/// One note = one PKDrawing in canvas coordinates. Pages are stacked vertically
/// with a fixed gap (PRD §8.2): `pageIndex = floor(y / (pageHeight + gap))`.
nonisolated struct PageGeometry: Equatable {
    static let gap: CGFloat = 16

    var pageSize: CGSize

    init(paper: Paper) { pageSize = paper.pageSize }

    var pitch: CGFloat { pageSize.height + Self.gap }

    func pageRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * pitch, width: pageSize.width, height: pageSize.height)
    }

    func pageIndex(forY y: CGFloat) -> Int { max(0, Int(floor(y / pitch))) }

    func contentHeight(pageCount: Int) -> CGFloat {
        CGFloat(pageCount) * pitch - Self.gap
    }

    /// Minimum pages needed to contain ink ending at `maxY`.
    func pagesNeeded(forMaxY maxY: CGFloat) -> Int { pageIndex(forY: maxY) + 1 }
}

/// Draws paper color + pattern. Used by the live canvas background, thumbnails, and PDF export.
nonisolated enum PaperRenderer {
    static func draw(paper: Paper, in rect: CGRect, context cg: CGContext) {
        cg.setFillColor(UIColor(hex: paper.color.hex).cgColor)
        cg.fill(rect)
        guard let path = patternPath(paper: paper, size: rect.size) else { return }
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.addPath(path)
        let pattern = UIColor(hex: paper.color.patternHex)
        if paper.style == .dot {
            cg.setFillColor(pattern.cgColor)
            cg.fillPath()
        } else {
            cg.setStrokeColor(pattern.cgColor)
            cg.setLineWidth(0.6)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    /// Pattern geometry in page coordinates. Ruled paper gets a top margin, like Notability's.
    static func patternPath(paper: Paper, size: CGSize) -> CGPath? {
        let pitch = paper.spacing.points
        let path = CGMutablePath()
        switch paper.style {
        case .blank:
            return nil
        case .ruled:
            var y = pitch * 2.5
            while y < size.height - pitch * 0.5 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += pitch
            }
        case .grid:
            let inset = (size.width.truncatingRemainder(dividingBy: pitch)) / 2
            var x = inset
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += pitch
            }
            let insetY = (size.height.truncatingRemainder(dividingBy: pitch)) / 2
            var y = insetY
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += pitch
            }
        case .dot:
            let r: CGFloat = 1.1
            let insetX = (size.width.truncatingRemainder(dividingBy: pitch)) / 2
            let insetY = (size.height.truncatingRemainder(dividingBy: pitch)) / 2
            var y = insetY
            while y <= size.height {
                var x = insetX
                while x <= size.width {
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += pitch
                }
                y += pitch
            }
        }
        return path
    }
}
