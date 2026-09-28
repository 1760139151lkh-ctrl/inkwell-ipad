import SwiftUI

/// The note's recordings: name · duration · date/time. Tap to select (shows its
/// transcript); the play glyph plays it from its start.
struct RecordingList: View {
    let editor: EditorModel
    let recordings: [Recording]
    let onRename: (Recording) -> Void
    let onDelete: (Recording) -> Void

    private var playback: PlaybackController { editor.playback }

    private var playingID: UUID? {
        guard playback.isEngaged, let loc = playback.timeline.locate(playback.currentTime) else { return nil }
        return playback.timeline.segments[loc.index].recordingID
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(recordings) { rec in
                    row(rec)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(CGFloat(recordings.count) * 62 + 4, 200))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ rec: Recording) -> some View {
        let selected = editor.selectedRecordingID == rec.id
        let isCurrent = playingID == rec.id
        return HStack(spacing: 12) {
            Button {
                editor.selectedRecordingID = rec.id
                if isCurrent && playback.isPlaying {
                    playback.pause()
                } else if isCurrent {
                    playback.play()
                } else if let offset = playback.timeline.offset(of: rec.id) {
                    playback.seek(to: offset)
                    playback.play()
                }
            } label: {
                ZStack {
                    Circle().fill(isCurrent ? Theme.accent : Theme.fieldBackground)
                        .frame(width: 34, height: 34)
                    PlayPauseGlyph(isPlaying: isCurrent && playback.isPlaying, size: 15)
                        .foregroundStyle(isCurrent ? .white : Theme.textPrimary)
                        .offset(x: isCurrent && playback.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(isCurrent && playback.isPlaying ? "Pause \(rec.name)" : "Play \(rec.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(rec.duration.shortDurationString) · \(rec.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if let p = editor.transcribing[rec.id] {
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }

            Menu {
                Button { onRename(rec) } label: { Label("Rename", systemImage: "pencil") }
                if rec.transcriptStatus != .complete {
                    Button { editor.transcribe(rec) } label: { Label("Transcribe", systemImage: "text.bubble") }
                }
                if SpeakerDetection.shared.isAvailable {
                    Button { editor.identifySpeakers(rec) } label: { Label("Identify Speakers", systemImage: "person.2") }
                }
                Divider()
                Button(role: .destructive) { onDelete(rec) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(rec.name) options")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.fieldBackground.opacity(0.9) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { editor.selectRecording(rec.id) }
    }
}

// MARK: - Transport (pinned at the bottom)

struct PanelTransport: View {
    let editor: EditorModel
    private var playback: PlaybackController { editor.playback }

    var body: some View {
        VStack(spacing: 8) {
            TimelineScrubber(playback: playback)
                .frame(height: 24)
            HStack {
                Text(playback.currentTime.clockString)
                Spacer()
                Text("-" + max(0, playback.duration - playback.currentTime).clockString)
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)

            HStack {
                Menu {
                    Picker("Playback Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                        ForEach(PlaybackController.speeds, id: \.self) { s in
                            Text(speedLabel(s)).tag(s)
                        }
                    }
                } label: {
                    Text(speedLabel(playback.rate))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 52, height: 30)
                        .background(Capsule().fill(Theme.fieldBackground))
                }
                .accessibilityLabel("Playback speed \(speedLabel(playback.rate))")

                Spacer()
                Button { playback.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 21)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back 10 seconds")
                Button { editor.playSelectedRecording() } label: {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 56, height: 56)
                        PlayPauseGlyph(isPlaying: playback.isPlaying, size: 24)
                            .foregroundStyle(Theme.panel)
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
                .padding(.horizontal, 10)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 21)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Forward 10 seconds")
                Spacer()
                Color.clear.frame(width: 52, height: 30)
            }
            .foregroundStyle(Theme.textPrimary)
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func speedLabel(_ s: Float) -> String {
        s == 1 ? "1×" : String(format: "%g×", s)
    }
}
