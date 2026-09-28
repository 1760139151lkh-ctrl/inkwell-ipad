import SwiftUI

/// Recordings panel — our own design, replacing Notability's playback popover and
/// Transcripts tab (PRD §6.12). A right-side rail, so the page you're writing on stays
/// visible. Top: recordings (or the live recording). Middle: the transcript. Bottom:
/// playback controls, pinned.
///
/// States: no recordings · recording live · recorded/idle · playing.
struct RecordingPanel: View {
    @Bindable var editor: EditorModel
    private var recorder: AudioRecorder { .shared }
    private var playback: PlaybackController { editor.playback }

    @State private var renaming: Recording?
    @State private var renameText = ""
    @State private var deleting: Recording?

    private var recordings: [Recording] { editor.note.orderedRecordings.filter { $0.duration > 0 } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if editor.isRecordingHere {
                LiveRecordingCard(editor: editor)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                LiveTranscriptView()
            } else if recordings.isEmpty {
                emptyState
            } else {
                RecordingList(editor: editor, recordings: recordings,
                              onRename: { rec in renameText = rec.name; renaming = rec },
                              onDelete: { rec in deleting = rec })
                    .padding(.horizontal, 10)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 8)
                SavedTranscriptView(editor: editor)
                PanelTransport(editor: editor)
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1) }
        .onChange(of: playback.currentTime) { _, t in followPlayhead(t) }
        .onChange(of: playback.isPlaying) { _, playing in
            // A new play session: let the selection follow wherever playback actually is.
            if playing { editor.lastPlayingRecordingID = nil }
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let r = renaming { editor.renameRecording(r, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                if let r = deleting { editor.deleteRecording(r) }
                deleting = nil
            }
        } message: {
            Text("The audio and its transcript will be removed. Your handwriting stays.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Recordings")
                    .font(Theme.serif(21, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if !recordings.isEmpty {
                    Text("\(recordings.count) · \(playback.duration.shortDurationString) total")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if !editor.isRecordingHere && !recordings.isEmpty {
                RecordButton(compact: true) { editor.toggleRecording() }
            }
            Button { editor.rail = .none } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.fieldBackground))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close recordings")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Theme.fieldBackground).frame(width: 76, height: 76)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("No recordings yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            RecordButton(compact: false) { editor.toggleRecording() }
                .padding(.top, 4)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// While playing, the selected recording follows the playhead.
    /// Selection follows the playhead only when playback crosses into another recording —
    /// otherwise a tap on a different recording would be overridden on the next tick.
    private func followPlayhead(_ t: TimeInterval) {
        guard playback.isPlaying, let loc = playback.timeline.locate(t) else { return }
        let id = playback.timeline.segments[loc.index].recordingID
        guard id != editor.lastPlayingRecordingID else { return }
        editor.lastPlayingRecordingID = id
        if editor.selectedRecordingID != id { editor.selectedRecordingID = id }
    }
}

// MARK: - Record button

struct RecordButton: View {
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(Color.white).frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
                Text(compact ? "Record" : "Start Recording")
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 20)
            .frame(height: compact ? 30 : 44)
            .background(Capsule().fill(Theme.recordRed))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Start recording")
    }
}

// MARK: - Live card

struct LiveRecordingCard: View {
    let editor: EditorModel
    private var recorder: AudioRecorder { .shared }

    private var name: String {
        editor.note.recordings.first { $0.id == recorder.recordingID }?.name ?? "Recording"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PulsingDot(color: Theme.recordRed, size: 9)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("REC")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.recordRed)
            }
            Text(recorder.elapsed.clockString)
                .font(.system(size: 44, weight: .light).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            LevelMeter(levels: recorder.levels, color: Theme.recordRed)
                .frame(height: 34)
            Button { editor.toggleRecording() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).frame(width: 11, height: 11)
                    Text("Stop Recording").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.recordRed))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.recordRed.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.recordRed.opacity(0.28)))
    }
}
