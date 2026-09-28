import SwiftUI

/// Transcript of the selected recording. While playing, it follows the playhead and
/// highlights the current line. Tap any line to seek there (the same seek as tapping ink).
struct SavedTranscriptView: View {
    let editor: EditorModel
    @State private var lastUserScroll = Date.distantPast
    @State private var flashSegment: Double?
    @State private var renaming: SpeakerRef?

    private var playback: PlaybackController { editor.playback }
    private var detection: SpeakerDetection { .shared }

    private var recording: Recording? {
        editor.note.recordings.first { $0.id == editor.selectedRecordingID }
    }

    private var transcript: Transcript? {
        guard let id = editor.selectedRecordingID else { return nil }
        return editor.transcripts[id]
    }

    /// Current segment start (recording-relative), if the playhead is inside the selected recording.
    private var currentSegmentStart: Double? {
        guard playback.isEngaged, let rec = recording, let t = transcript,
              let offset = playback.timeline.offset(of: rec.id) else { return nil }
        let local = playback.currentTime - offset
        guard local >= 0, local <= rec.duration + 0.05 else { return nil }
        return t.segments.last(where: { $0.start <= local + 0.05 })?.start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRANSCRIPT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let rec = recording {
                    speakerStatus(rec)
                    Text(rec.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if let rec = recording {
                if let t = transcript, !t.segments.isEmpty {
                    segmentsList(t, recording: rec)
                } else {
                    noTranscript(rec)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $renaming) { ref in
            SpeakerNameSheet(current: editor.speakerName(recordingID: ref.recordingID, label: ref.label),
                             color: SpeakerDirectory.color(for: ref.label)) { name in
                editor.renameSpeaker(recordingID: ref.recordingID, label: ref.label, to: name)
            }
        }
    }

    private func segmentsList(_ t: Transcript, recording rec: Recording) -> some View {
        let current = currentSegmentStart
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { i, seg in
                        // Speaker label on the first line of each speaker's turn.
                        if let label = seg.speaker, i == 0 || t.segments[i - 1].speaker != label {
                            SpeakerChip(name: editor.speakerName(recordingID: rec.id, label: label),
                                        color: SpeakerDirectory.color(for: label)) {
                                renaming = SpeakerRef(recordingID: rec.id, label: label)
                            }
                            .padding(.leading, 58)
                            .padding(.top, i == 0 ? 2 : 10)
                        }
                        TranscriptLine(time: seg.start, text: seg.text,
                                       state: lineState(seg, current: current))
                            .id(i)   // index, not start time: overlapping speakers can share a start
                            .onTapGesture { editor.seek(recordingID: rec.id, local: seg.start) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Plays from here")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in lastUserScroll = Date() })
            .onChange(of: current) { _, start in
                guard let start, playback.isPlaying, Date().timeIntervalSince(lastUserScroll) > 4,
                      let row = t.segments.lastIndex(where: { $0.start == start }) else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(row, anchor: UnitPoint(x: 0.5, y: 0.5)) }
            }
            .onAppear { scrollToFocus(proxy, t) }
            .onChange(of: editor.focusSegmentStart) { _, _ in scrollToFocus(proxy, t) }
        }
    }

    /// Header status: detecting / failed / an "Identify speakers" action.
    @ViewBuilder
    private func speakerStatus(_ rec: Recording) -> some View {
        let hasSpeakers = !(transcript?.speakers.isEmpty ?? true)
        switch detection.status[rec.id] {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.textTertiary)
                Text("Finding speakers…")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
        case .waitingForUpload:
            Text("Speakers after upload")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        case .failed(let msg):
            Button { editor.identifySpeakers(rec) } label: {
                Label("Retry speakers", systemImage: "exclamationmark.triangle")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .help(msg)
        case .done:
            // A successful run that finds a single speaker used to render nothing at all, which is
            // indistinguishable from the button doing nothing. Always report the outcome.
            let n = transcript?.speakers.count ?? 0
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                Text(n == 1 ? "1 speaker found" : "\(n) speakers found")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
        default:
            if !hasSpeakers, detection.isAvailable, transcript != nil {
                Button { editor.identifySpeakers(rec) } label: {
                    Label("Identify speakers", systemImage: "person.2")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func lineState(_ seg: Transcript.Segment, current: Double?) -> TranscriptLine.LineState {
        if flashSegment == seg.start { return .current }
        guard let current else { return .idle }
        if seg.start == current { return .current }
        return seg.start < current ? .played : .upcoming
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy, _ t: Transcript) {
        guard let focus = editor.focusSegmentStart else { return }
        editor.focusSegmentStart = nil
        flashSegment = focus
        if let row = t.segments.firstIndex(where: { $0.start == focus }) {
            DispatchQueue.main.async { proxy.scrollTo(row, anchor: .center) }
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.6)) { flashSegment = nil }
        }
    }

    @ViewBuilder
    private func noTranscript(_ rec: Recording) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if let p = editor.transcribing[rec.id] {
                ProgressView(value: p).tint(Theme.accent).frame(width: 160)
                Text("Transcribing… \(Int(p * 100))%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else if detection.status[rec.id] == .running {
                ProgressView().tint(Theme.textTertiary)
                Text("Transcribing with speaker detection…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(rec.transcriptStatus == .failed ? "Transcription failed" : "No transcript")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Button { editor.transcribe(rec) } label: {
                    Label("Transcribe", systemImage: "text.bubble")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Theme.accentSoft))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct TranscriptLine: View {
    enum LineState { case idle, played, current, upcoming, volatile }

    let time: Double
    let text: String
    let state: LineState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time.clockString)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(state == .current ? Theme.accent : Theme.textTertiary)
                .frame(width: 38, alignment: .trailing)
            Text(text)
                .font(.system(size: 15, weight: state == .current ? .medium : .regular))
                .italic(state == .volatile)
                .foregroundStyle(textColor)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state == .current ? Theme.accentSoft : .clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var textColor: Color {
        switch state {
        case .idle: Theme.textPrimary.opacity(0.84)
        case .played: Theme.textPrimary.opacity(0.62)
        case .current: Theme.textPrimary
        case .upcoming: Theme.textPrimary.opacity(0.42)
        case .volatile: Theme.textPrimary.opacity(0.66)
        }
    }
}

/// Live transcript while recording: finals solid, volatile text dimmed (PRD §6.12).
struct LiveTranscriptView: View {
    private var recorder: AudioRecorder { .shared }
    @State private var lastUserScroll = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("LIVE TRANSCRIPT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)

            if !recorder.liveTranscriptionActive {
                VStack(spacing: 8) {
                    Spacer()
                    Text(AppSettings.shared.liveTranscription ? "Live transcription isn’t available right now" : "Live transcription is off")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("You can transcribe this recording after you stop.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Spacer()
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            } else if recorder.liveFinals.isEmpty && recorder.liveVolatile.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ListeningIndicator()
                    Text("Listening…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(recorder.liveFinals) { seg in
                                TranscriptLine(time: seg.start, text: seg.text, state: .idle)
                                    .id(seg.start)
                            }
                            if !recorder.liveVolatile.isEmpty {
                                TranscriptLine(time: (recorder.liveFinals.last?.end ?? 0), text: recorder.liveVolatile, state: .volatile)
                                    .id("volatile")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 16)
                    }
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in lastUserScroll = Date() })
                    .onChange(of: recorder.liveFinals.count) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: recorder.liveVolatile) { _, _ in scrollToBottom(proxy) }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard Date().timeIntervalSince(lastUserScroll) > 4 else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

struct ListeningIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

// MARK: - Speakers

struct SpeakerRef: Identifiable {
    var recordingID: UUID
    var label: String
    var id: String { "\(recordingID.uuidString):\(label)" }
}

/// "● Kunal" above a speaker's turn. Tap to rename.
struct SpeakerChip: View {
    let name: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(color)
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color.opacity(0.7))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(color.opacity(0.14)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Speaker \(name). Rename.")
    }
}

/// Name a speaker; suggestions come from names used before.
struct SpeakerNameSheet: View {
    let current: String
    let color: Color
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let q = name.trimmingCharacters(in: .whitespaces)
        let all = SpeakerDirectory.names
        return q.isEmpty ? Array(all.prefix(8)) : all.filter { $0.localizedCaseInsensitiveContains(q) && $0 != q }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Who is this?").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Save") { save(name) }.fontWeight(.semibold)
            }
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                TextField("", text: $name, prompt: Text(current).foregroundStyle(Theme.textTertiary))
                    .font(.system(size: 17, weight: .medium))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save(name) }
                    .textInputAutocapitalization(.words)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fieldBackground))
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                    FlowChips(items: suggestions) { save($0) }
                }
            }
            Text("Applies to every line from this speaker in this recording.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.sidebar)
        .presentationDetents([.height(300)])
        .onAppear {
            name = current.hasPrefix("Speaker ") ? "" : current
            focused = true
        }
    }

    private func save(_ value: String) {
        onSave(value)
        dismiss()
    }
}

/// Wrapping row of tappable name chips.
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ForEach(items.prefix(4), id: \.self, content: chip) }
                HStack(spacing: 8) { ForEach(items.dropFirst(4), id: \.self, content: chip) }
            }
        }
    }

    @ViewBuilder private var chips: some View { ForEach(items, id: \.self, content: chip) }

    private func chip(_ item: String) -> some View {
        Button { onTap(item) } label: {
            Text(item)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Theme.fieldBackground))
        }
        .buttonStyle(PressableStyle())
    }
}
