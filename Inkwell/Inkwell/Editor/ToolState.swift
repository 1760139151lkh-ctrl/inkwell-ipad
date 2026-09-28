import Foundation
import Observation
import PencilKit
import UIKit

enum ToolKind: String, CaseIterable, Identifiable, Codable {
    case text, lasso, pen, pencil, highlighter, eraser, navigate
    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .lasso: "Lasso"
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .navigate: "Navigate"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .lasso: "lasso"
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .navigate: "hand.point.up.left"
        }
    }

    var isInk: Bool { self == .pen || self == .pencil || self == .highlighter }
    var hasSubBar: Bool { self != .navigate }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    case stroke, partial
    var id: String { rawValue }
    var label: String { self == .stroke ? "Stroke" : "Partial" }
}

/// Favorites + width for one ink tool (PRD §6.5). Persisted per tool across notes.
struct InkToolConfig: Codable, Equatable {
    var favorites: [String]     // 3 hex colors
    var selectedColor: Int      // 0…2
    var widthIndex: Int         // 0…2

    var colorHex: String { favorites[min(selectedColor, favorites.count - 1)] }
}

@Observable final class ToolState {
    static let shared = ToolState()
    private let defaults = UserDefaults.standard

    var current: ToolKind { didSet { save() } }
    /// Tool to return to when Pencil double-tap toggles back from the eraser.
    var previousTool: ToolKind = .pen
    var pen: InkToolConfig { didSet { save() } }
    var pencil: InkToolConfig { didSet { save() } }
    var highlighter: InkToolConfig { didSet { save() } }
    var eraserMode: EraserMode { didSet { save() } }
    var eraserSize: Int { didSet { save() } }
    /// Text tool (PRD §6.5): size S/M/L, bold, 3 favorite colors.
    var text: TextToolConfig { didSet { save() } }

    static let penWidths: [CGFloat] = [1.6, 3.0, 5.0]
    static let pencilWidths: [CGFloat] = [2.0, 3.5, 6.0]
    static let highlighterWidths: [CGFloat] = [10, 16, 24]
    static let eraserWidths: [CGFloat] = [8, 18, 36]

    private init() {
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return v
        }
        current = load("tool.current", ToolKind.pen)
        pen = load("tool.pen", InkToolConfig(favorites: ["#1A1A1A", "#2F6FE4", "#E0343C"], selectedColor: 0, widthIndex: 1))
        pencil = load("tool.pencil", InkToolConfig(favorites: ["#4A4A4A", "#2F6FE4", "#E0343C"], selectedColor: 0, widthIndex: 1))
        highlighter = load("tool.highlighter", InkToolConfig(favorites: ["#FFE14D", "#FF7AC6", "#7CE38B"], selectedColor: 0, widthIndex: 1))
        eraserMode = load("tool.eraserMode", EraserMode.stroke)
        eraserSize = load("tool.eraserSize", 1)
        text = load("tool.text", TextToolConfig())
    }

    private func save() {
        let e = JSONEncoder()
        defaults.set(try? e.encode(current), forKey: "tool.current")
        defaults.set(try? e.encode(pen), forKey: "tool.pen")
        defaults.set(try? e.encode(pencil), forKey: "tool.pencil")
        defaults.set(try? e.encode(highlighter), forKey: "tool.highlighter")
        defaults.set(try? e.encode(eraserMode), forKey: "tool.eraserMode")
        defaults.set(try? e.encode(eraserSize), forKey: "tool.eraserSize")
        defaults.set(try? e.encode(text), forKey: "tool.text")
    }

    func config(for tool: ToolKind) -> InkToolConfig? {
        switch tool {
        case .pen: pen
        case .pencil: pencil
        case .highlighter: highlighter
        default: nil
        }
    }

    func update(_ tool: ToolKind, _ change: (inout InkToolConfig) -> Void) {
        switch tool {
        case .pen: change(&pen)
        case .pencil: change(&pencil)
        case .highlighter: change(&highlighter)
        default: break
        }
    }

    static func widths(for tool: ToolKind) -> [CGFloat] {
        switch tool {
        case .pen: penWidths
        case .pencil: pencilWidths
        case .highlighter: highlighterWidths
        case .eraser: eraserWidths
        default: []
        }
    }

    /// The PencilKit tool for the current selection. `nil` for Navigate.
    var pkTool: PKTool? {
        switch current {
        case .pen:
            return PKInkingTool(.pen, color: UIColor(hex: pen.colorHex), width: Self.penWidths[pen.widthIndex])
        case .pencil:
            return PKInkingTool(.pencil, color: UIColor(hex: pencil.colorHex), width: Self.pencilWidths[pencil.widthIndex])
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(hex: highlighter.colorHex).withAlphaComponent(0.9),
                                width: Self.highlighterWidths[highlighter.widthIndex])
        case .eraser:
            let type: PKEraserTool.EraserType = eraserMode == .stroke ? .vector : .bitmap
            return PKEraserTool(type, width: Self.eraserWidths[eraserSize])
        case .lasso:
            return PKLassoTool()
        case .navigate, .text:
            return nil
        }
    }

    func select(_ tool: ToolKind) {
        if current != .eraser { previousTool = current }
        current = tool
    }

    /// Apple Pencil double-tap: current tool ↔ eraser.
    func toggleEraser() {
        if current == .eraser {
            current = previousTool == .eraser ? .pen : previousTool
        } else {
            previousTool = current
            current = .eraser
        }
    }
}

struct TextToolConfig: Codable, Equatable {
    static let sizes: [CGFloat] = [13, 17, 24]
    var sizeIndex = 1
    var bold = false
    var favorites = ["#1A1A1A", "#2F6FE4", "#E0343C"]
    var selectedColor = 0

    var fontSize: CGFloat { Self.sizes[min(sizeIndex, Self.sizes.count - 1)] }
    var colorHex: String { favorites[min(selectedColor, favorites.count - 1)] }
}
