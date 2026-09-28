import SwiftUI

/// Paper sheet (PRD §6.11): Style · Color · Orientation. Applies to the whole note.
struct PaperSheet: View {
    let initial: Paper
    var applyTitle = "Apply"
    let onApply: (Paper) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var paper: Paper

    init(initial: Paper, applyTitle: String = "Apply", onApply: @escaping (Paper) -> Void) {
        self.initial = initial
        self.applyTitle = applyTitle
        self.onApply = onApply
        _paper = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Paper").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(applyTitle) {
                    onApply(paper)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    // Style
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            sectionTitle("Style")
                            Spacer()
                            orientationToggle
                        }
                        HStack(alignment: .top, spacing: 22) {
                            ForEach(PaperStyle.allCases) { style in
                                styleCard(style)
                            }
                        }
                    }

                    // Color
                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Color")
                        HStack(spacing: 18) {
                            ForEach(PaperColor.allCases) { color in
                                Button { paper.color = color } label: {
                                    Circle()
                                        .fill(Color(hex: color.hex))
                                        .frame(width: 40, height: 40)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                        .overlay(
                                            Circle().strokeBorder(Theme.accent, lineWidth: 3)
                                                .padding(-6)
                                                .opacity(paper.color == color ? 1 : 0)
                                        )
                                        .padding(6)
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel(color.label)
                                .accessibilityAddTraits(paper.color == color ? .isSelected : [])
                            }
                        }
                    }

                    // Size is fixed to US Letter in Phase 1 (PRD §6.11).
                    HStack(spacing: 6) {
                        Text("Size")
                            .foregroundStyle(Theme.textSecondary)
                        Text("US Letter")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.sidebar)
        .presentationSizing(.page)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.serif(22, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
    }

    private var orientationToggle: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { landscape in
                Button { paper.landscape = landscape } label: {
                    HStack(spacing: 6) {
                        Image(systemName: landscape ? "rectangle" : "rectangle.portrait")
                        Text(landscape ? "Landscape" : "Portrait")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(paper.landscape == landscape ? .white : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(paper.landscape == landscape ? Theme.accent : .clear))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fieldBackground))
    }

    private func styleCard(_ style: PaperStyle) -> some View {
        let selected = paper.style == style
        let previewPaper = Paper(style: style, color: paper.color, spacing: paper.spacing, landscape: paper.landscape)
        let size = paper.landscape ? CGSize(width: 180, height: 139) : CGSize(width: 139, height: 180)
        return VStack(spacing: 10) {
            Button { paper.style = style } label: {
                PaperPreview(paper: previewPaper)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 3)
                            .padding(-4)
                    )
                    .overlay(alignment: .top) {
                        if selected {
                            Text("CURRENT")
                                .font(.system(size: 9.5, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.accent))
                                .offset(y: -12)
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(style.label)
            .accessibilityAddTraits(selected ? .isSelected : [])

            HStack(spacing: 2) {
                Text(style.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                if style != .blank {
                    Menu {
                        Picker("Spacing", selection: Binding(get: { paper.spacing }, set: {
                            paper.spacing = $0
                            paper.style = style
                        })) {
                            ForEach(PaperSpacing.allCases) { s in Text(s.label).tag(s) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                    }
                    .accessibilityLabel("\(style.label) spacing")
                }
            }
            .frame(height: 26)
        }
    }
}

/// Renders a small paper page with its pattern (Paper sheet + Settings previews).
struct PaperPreview: View {
    let paper: Paper

    var body: some View {
        Canvas { ctx, size in
            let page = paper.pageSize
            let scale = min(size.width / page.width, size.height / page.height)
            ctx.scaleBy(x: scale, y: scale)
            ctx.fill(Path(CGRect(origin: .zero, size: page)), with: .color(Color(hex: paper.color.hex)))
            if let pattern = PaperRenderer.patternPath(paper: paper, size: page) {
                let color = Color(hex: paper.color.patternHex)
                if paper.style == .dot {
                    ctx.fill(Path(pattern), with: .color(color))
                } else {
                    ctx.stroke(Path(pattern), with: .color(color), lineWidth: 1.2)
                }
            }
        }
    }
}
