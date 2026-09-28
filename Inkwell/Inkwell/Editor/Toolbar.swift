import SwiftUI

/// Main floating toolbar (PRD §6.5): Lasso · Pen · Pencil · Highlighter · Eraser | Record · Play | Navigate.
struct MainToolbar: View {
    let editor: EditorModel
    private var tools: ToolState { .shared }

    var body: some View {
        ChromePill(cornerRadius: 12) {
            toolButton(.text)
            toolButton(.lasso)
            mediaButton
            toolButton(.pen)
            toolButton(.pencil)
            toolButton(.highlighter)
            toolButton(.eraser)
            PillDivider()
            recordButton
            if editor.playback.hasAudio || !editor.note.recordings.isEmpty {
                playButton
            }
            PillDivider()
            toolButton(.navigate)
        }
        .animation(.snappy(duration: 0.2), value: editor.playback.hasAudio)
    }

    private func toolButton(_ tool: ToolKind) -> some View {
        let active = tools.current == tool
        return Button { editor.select(tool) } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 21, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.accent : Theme.textPrimary.opacity(0.9))
                    .frame(width: 43, height: 44)
                if let config = tools.config(for: tool) {
                    Capsule()
                        .fill(Color(hex: config.colorHex))
                        .frame(width: 16, height: 3)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .padding(.bottom, 3)
                        .opacity(active ? 1 : 0.85)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.accentSoft : .clear)
                    .padding(2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Media (PRD §6.5 #3): opens the photo picker; the image lands on the visible page.
    private var mediaButton: some View {
        Button { editor.showPhotoPicker = true } label: {
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .frame(width: 43, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Insert Photo")
    }

    private var recordButton: some View {
        let recording = editor.isRecordingHere
        return Button { editor.toggleRecording() } label: {
            ZStack {
                if recording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.recordRed)
                        .padding(4)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 21))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                }
            }
            .frame(width: 43, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(recording ? "Stop Recording" : "Record")
    }

    private var playButton: some View {
        let playing = editor.playback.isPlaying
        return Button { editor.togglePlayback() } label: {
            PlayPauseGlyph(isPlaying: playing, size: 20)
                .foregroundStyle(editor.isRecordingHere ? Theme.textTertiary : (editor.playback.isEngaged ? Theme.accent : Theme.textPrimary.opacity(0.9)))
                .frame(width: 43, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(editor.isRecordingHere || !editor.playback.hasAudio)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

// MARK: - Sub-bar container

struct SubBarPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.pill.opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.pillBorder)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }
}

// MARK: - Tool sub-bar (PRD §6.5)

struct ToolSubBar: View {
    let tool: ToolKind
    let editor: EditorModel
    private var tools: ToolState { .shared }

    var body: some View {
        SubBarPill {
            switch tool {
            case .text:
                textOptions
            case .pen, .pencil, .highlighter:
                inkOptions
            case .eraser:
                eraserOptions
            case .lasso:
                HStack(spacing: 6) {
                    Image(systemName: "lasso").font(.system(size: 13))
                    Text("Freeform").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Theme.accentSoft))
            case .navigate:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var inkOptions: some View {
        if let config = tools.config(for: tool) {
            ForEach(0..<3, id: \.self) { i in
                let hex = config.favorites[i]
                Button {
                    tools.update(tool) { $0.selectedColor = i }
                    editor.applyTool()
                } label: {
                    ColorSwatch(hex: hex, selected: config.selectedColor == i)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Color \(i + 1)")
            }
            ColorPicker("", selection: Binding(
                get: { Color(hex: config.colorHex) },
                set: { newColor in
                    tools.update(tool) { $0.favorites[$0.selectedColor] = UIColor(newColor).hexString }
                    editor.applyTool()
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40, height: 40)
                .accessibilityLabel("Custom color")

            Rectangle().fill(Theme.pillBorder).frame(width: 1, height: 22).padding(.horizontal, 6)

            ForEach(0..<3, id: \.self) { i in
                Button {
                    tools.update(tool) { $0.widthIndex = i }
                    editor.applyTool()
                } label: {
                    WidthDot(diameter: [6, 10, 14][i], selected: config.widthIndex == i,
                             color: Color(hex: config.colorHex), isHighlighter: tool == .highlighter)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(["Thin", "Medium", "Thick"][i])
            }
        }
    }

    @ViewBuilder
    private var textOptions: some View {
        let cfg = tools.text
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    tools.text.sizeIndex = i
                    editor.applyTextStyleToSelection()
                } label: {
                    Text("A")
                        .font(.system(size: [13, 16, 20][i], weight: .semibold))
                        .foregroundStyle(cfg.sizeIndex == i ? .white : Theme.textSecondary)
                        .frame(width: 34, height: 30)
                        .background(Capsule().fill(cfg.sizeIndex == i ? Theme.accent : .clear))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(["Small", "Medium", "Large"][i] + " text")
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fieldBackground))

        Button {
            tools.text.bold.toggle()
            editor.applyTextStyleToSelection()
        } label: {
            Image(systemName: "bold")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(cfg.bold ? Theme.accent : Theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(cfg.bold ? Theme.accentSoft : .clear).padding(2))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Bold")
        .accessibilityAddTraits(cfg.bold ? .isSelected : [])

        Rectangle().fill(Theme.pillBorder).frame(width: 1, height: 22).padding(.horizontal, 6)

        ForEach(0..<3, id: \.self) { i in
            Button {
                tools.text.selectedColor = i
                editor.applyTextStyleToSelection()
            } label: {
                ColorSwatch(hex: cfg.favorites[i], selected: cfg.selectedColor == i)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Text color \(i + 1)")
        }
        ColorPicker("", selection: Binding(
            get: { Color(hex: cfg.colorHex) },
            set: { c in
                tools.text.favorites[tools.text.selectedColor] = UIColor(c).hexString
                editor.applyTextStyleToSelection()
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 40, height: 40)
            .accessibilityLabel("Custom text color")
    }

    @ViewBuilder
    private var eraserOptions: some View {
        HStack(spacing: 2) {
            ForEach(EraserMode.allCases) { mode in
                Button {
                    tools.eraserMode = mode
                    editor.applyTool()
                } label: {
                    Text(mode.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tools.eraserMode == mode ? .white : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(tools.eraserMode == mode ? Theme.accent : .clear))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fieldBackground))

        Rectangle().fill(Theme.pillBorder).frame(width: 1, height: 22).padding(.horizontal, 6)

        ForEach(0..<3, id: \.self) { i in
            Button {
                tools.eraserSize = i
                editor.applyTool()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(tools.eraserSize == i ? Theme.accent : Theme.textSecondary, lineWidth: 1.5)
                        .frame(width: [10, 15, 21][i], height: [10, 15, 21][i])
                }
                .frame(width: 34, height: 34)
                .background(Circle().fill(tools.eraserSize == i ? Theme.accentSoft : .clear).padding(2))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(["Small", "Medium", "Large"][i] + " eraser")
        }
    }
}

struct ColorSwatch: View {
    let hex: String
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            Circle()
                .strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                .frame(width: 34, height: 34)
        }
        .frame(width: 40, height: 40)
    }
}

struct WidthDot: View {
    let diameter: CGFloat
    let selected: Bool
    let color: Color
    let isHighlighter: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? Theme.accentSoft : .clear)
                .frame(width: 36, height: 36)
            Group {
                if isHighlighter {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: diameter * 0.7, height: diameter * 1.25)
                } else {
                    Circle().frame(width: diameter, height: diameter)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Recording bar (sub-bar while recording, PRD §6.6)

struct RecordingBar: View {
    let editor: EditorModel
    private var recorder: AudioRecorder { .shared }

    var body: some View {
        SubBarPill {
            Button { editor.rail = .recordings } label: {
                HStack(spacing: 8) {
                    PulsingDot(color: Theme.recordRed, size: 9)
                    Text("REC")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.recordRed)
                    Text(recorder.elapsed.clockString)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 52, alignment: .leading)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Recording \(recorder.elapsed.clockString). Show recordings.")

            LevelMeter(levels: Array(recorder.levels.suffix(28)), color: Theme.recordRed)
                .frame(width: 118, height: 22)
                .padding(.horizontal, 6)

            if recorder.liveTranscriptionActive, let text = latestTranscript {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 240, alignment: .leading)
            }

            Button { editor.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    Text("Stop").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Theme.recordRed))
            }
            .buttonStyle(PressableStyle())
            .padding(.leading, 4)
        }
    }

    private var latestTranscript: String? {
        let v = recorder.liveVolatile
        if !v.isEmpty { return v }
        return recorder.liveFinals.last?.text
    }
}

/// Live input level bars, newest on the right.
struct LevelMeter: View {
    let levels: [Float]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let w = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    Capsule()
                        .fill(color.opacity(0.35 + 0.65 * Double(i) / Double(count)))
                        .frame(width: max(1.5, w), height: max(2, geo.size.height * CGFloat(level)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Playback bar (PRD §6.7)

struct PlaybackBar: View {
    let editor: EditorModel
    private var playback: PlaybackController { editor.playback }

    var body: some View {
        SubBarPill {
            // Play/pause lives here too, at the left, where your thumb already is.
            Button { editor.togglePlayback() } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 36, height: 36)
                    PlayPauseGlyph(isPlaying: playback.isPlaying, size: 16)
                        .foregroundStyle(Theme.pill)
                        .offset(x: playback.isPlaying ? 0 : 1.5)
                }
                .frame(width: 42, height: 42)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 20)).frame(width: 40, height: 40)
            }
            .accessibilityLabel("Back 10 seconds")
            Button { playback.skip(10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 20)).frame(width: 40, height: 40)
            }
            .accessibilityLabel("Forward 10 seconds")

            TimelineScrubber(playback: playback)
                .frame(width: 300, height: 30)
                .padding(.horizontal, 6)

            Text("\(playback.currentTime.clockString) / \(playback.duration.clockString)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 92)

            Button { editor.rail = .recordings } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 21)).frame(width: 40, height: 40)
            }
            .accessibilityLabel("Recordings and speed")

            Button { playback.disengage() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.fieldBackground))
            }
            .accessibilityLabel("Close playback")
        }
        .foregroundStyle(Theme.textPrimary)
        .buttonStyle(PressableStyle())
    }
}

/// Scrubber across the whole note timeline, with a tick at each recording boundary.
struct TimelineScrubber: View {
    let playback: PlaybackController
    var trackHeight: CGFloat = 4
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(playback.duration, 0.001)
            let progress = (dragValue ?? playback.currentTime) / total
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: trackHeight)
                Capsule().fill(Theme.accent).frame(width: max(0, w * progress), height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: w * progress - 7)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = max(0, min(1, v.location.x / w)) * total
                        dragValue = t
                        playback.seek(to: t)
                    }
                    .onEnded { _ in dragValue = nil }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(playback.currentTime.clockString) of \(playback.duration.clockString)")
        .accessibilityAdjustableAction { dir in
            playback.skip(dir == .increment ? 10 : -10)
        }
    }
}
