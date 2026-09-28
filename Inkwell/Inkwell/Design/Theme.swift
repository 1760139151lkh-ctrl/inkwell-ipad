import SwiftUI
import UIKit

/// Phase 1 visual language (PRD §6.1): Notability-like dark chrome, white paper.
enum Theme {
    // Chrome
    static let sidebar = Color(hex: "#1E2229")
    static let noteList = Color(hex: "#15181D")
    static let editorChrome = Color(hex: "#1E2229")
    static let canvasBackdrop = Color(hex: "#2A2F37")
    static let pill = Color(hex: "#15181D")
    static let pillBorder = Color(hex: "#2E333B")
    static let hairline = Color.white.opacity(0.07)
    static let rowSelected = Color(hex: "#353B45")
    static let noteRowSelected = Color(hex: "#232A36")
    static let fieldBackground = Color(hex: "#2A2F37")
    static let panel = Color(hex: "#191C22")

    // Content
    static let accent = Color(hex: "#4A90E2")
    static let accentSoft = Color(hex: "#4A90E2").opacity(0.18)
    static let recordRed = Color(hex: "#FF453A")
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.34)
    static let footerText = Color(hex: "#8E9BB0")

    static let uiCanvasBackdrop = UIColor(hex: "#2A2F37")

    // Type — SF Pro for UI, New York for display titles.
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func uiSerif(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// The subject palette (PRD §6.1: ~8 swatches).
enum SubjectPalette {
    static let swatches: [String] = [
        "#8BC77A", // light green
        "#2F7D46", // dark green
        "#4FB3A9", // teal
        "#B8324B", // crimson
        "#E0603A", // orange-red
        "#4A90E2", // blue
        "#8E6BD8", // purple
        "#E6B93C", // yellow
    ]
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    nonisolated convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    nonisolated var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

// MARK: - Shared chrome components

/// A square-ish dark button with a hairline border, as used for Library toggle / ⋯ / content manager.
struct ChromeIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var tint: Color = Theme.textPrimary
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isActive ? Theme.accent : tint)
                .frame(width: 40, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Container that draws the dark rounded pill behind a group of chrome buttons.
struct ChromePill<Content: View>: View {
    var cornerRadius: CGFloat = 11
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.pill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.pillBorder, lineWidth: 1)
            )
    }
}

/// Play / pause from Phosphor Icons (MIT): a rounded glyph instead of SF Symbols' bare triangle.
struct PlayPauseGlyph: View {
    var isPlaying: Bool
    var size: CGFloat

    var body: some View {
        Image(isPlaying ? "ph.pause-fill" : "ph.play-fill")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct PillDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.pillBorder)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 5)
    }
}

extension TimeInterval {
    /// "12:48" or "1:02:03"
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "12m 49s"
    var shortDurationString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
