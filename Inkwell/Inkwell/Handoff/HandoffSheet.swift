import SwiftUI
import UIKit

/// One tap → a link any agent (Claude, ChatGPT, Claude Code, Codex) can read, with a
/// ready-to-paste prompt already on the clipboard.
@MainActor @Observable final class HandoffController {
    enum Step: Int, CaseIterable {
        case backup, reading, uploading, link
        var label: String {
            switch self {
            case .backup: "Backing up the note"
            case .reading: "Reading your handwriting"
            case .uploading: "Packaging notes and pages"
            case .link: "Creating a private link"
            }
        }
    }

    enum State: Equatable {
        case working(Step)
        case ready(url: String, prompt: String, expires: Date?)
        case failed(String)
        case needsSignIn(String)
    }

    private(set) var state: State = .working(.backup)
    private(set) var copied = false
    private var task: Task<Void, Never>?

    /// Starts a handoff unless one is already running (double taps, Try Again spam).
    func start(editor: EditorModel) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(editor: editor)
            self?.task = nil
        }
    }

    /// The sheet closed: stop, so a late finish can't create a link or overwrite the clipboard.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(editor: EditorModel) async {
        state = .working(.backup)
        copied = false
        let note = editor.note
        do {
            editor.flush()
            try await BackupEngine.shared.ensureBackedUp(note.id)

            state = .working(.reading)
            let timeline = NoteTimeline(note.orderedRecordings.filter { $0.duration > 0 }.map { ($0.id, $0.startedAt, $0.duration) })
            let drawing = editor.canvas.drawing
            let pdfURL = note.pdfBackgroundFile.map { NoteFiles.folder(note.id).appendingPathComponent($0) }
            let (noteID, title, paper, pages, elements) = (note.id, note.title, note.paper, editor.pageCount, editor.elementSnapshots)
            let build = Task.detached(priority: .userInitiated) {
                try await HandoffBuilder.build(noteID: noteID, title: title, paper: paper, pageCount: pages, drawing: drawing,
                                               pdf: pdfURL.flatMap { CGPDFDocument($0 as CFURL) }, elements: elements,
                                               timeline: timeline)
            }
            let package = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
            defer { try? FileManager.default.removeItem(at: package.folder) }
            try Task.checkCancellation()

            state = .working(.uploading)
            var files: [(path: String, url: URL, contentType: String)] = [("export/notes.pdf", package.pdfURL, "application/pdf")]
            for (i, url) in package.pageImages.enumerated() { files.append(("export/page-\(i + 1).png", url, "image/png")) }
            let keys = try await BackupEngine.shared.uploadExports(noteID: note.id, files: files)
            try Task.checkCancellation()

            state = .working(.link)
            guard let api = BackupEngine.shared.api else { throw BackupEngine.HandoffError(message: BackupEngine.signInMessage, needsSignIn: true) }
            var pagesJSON: [[String: Any]] = []
            for i in package.pageImages.indices {
                var page: [String: Any] = ["index": i, "text": package.pageText[safe: i] ?? ""]
                page["png_key"] = keys["export/page-\(i + 1).png"] ?? NSNull()
                pagesJSON.append(page)
            }
            var momentsJSON: [[String: Any]] = []
            for m in package.moments {
                let bbox: [Double] = [m.bbox.minX, m.bbox.minY, m.bbox.width, m.bbox.height].map { (Double($0) * 10).rounded() / 10 }
                var moment: [String: Any] = ["page": m.page, "bbox": bbox, "text": m.text]
                moment["t_start"] = m.tStart.map { ($0 * 100).rounded() / 100 } ?? NSNull()
                moment["t_end"] = m.tEnd.map { ($0 * 100).rounded() / 100 } ?? NSNull()
                momentsJSON.append(moment)
            }
            var body: [String: Any] = ["pages": pagesJSON, "moments": momentsJSON, "expires_in_days": 30,
                                        "time_zone": TimeZone.current.identifier]
            body["pdf_key"] = keys["export/notes.pdf"] ?? NSNull()
            let resp = try await api.call("POST", "api/notes/\(note.id.lowercased)/handoff", body: try BackupAPI.json(body))
            guard let url = resp["url"] as? String else { throw BackupEngine.HandoffError(message: "The server didn’t return a link.") }
            try Task.checkCancellation()
            let prompt = Self.prompt(note: note, url: url, speakers: speakerNames(editor))
            state = .ready(url: url, prompt: prompt, expires: BackupAPI.date(resp["expires_at"]))
            copy(prompt)
        } catch is CancellationError {
            return
        } catch let e as BackupEngine.HandoffError where e.needsSignIn {
            state = .needsSignIn(e.message)
        } catch {
            if Task.isCancelled { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func speakerNames(_ editor: EditorModel) -> [String] {
        var names: [String] = []
        for rec in editor.note.orderedRecordings {
            for label in editor.transcripts[rec.id]?.speakers ?? [] {
                let n = editor.speakerName(recordingID: rec.id, label: label)
                if !n.hasPrefix("Speaker "), !names.contains(n) { names.append(n) }
            }
        }
        return names
    }

    /// Short, agent-agnostic prompt. The link carries everything else.
    static func prompt(note: Note, url: String, speakers: [String]) -> String {
        var context = note.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
        if let subject = note.subject?.name { context = "\(subject) · \(context)" }
        if !speakers.isEmpty { context += " · with \(speakers.joined(separator: ", "))" }
        return """
        Here are my notes from a call — “\(note.title)” (\(context)).

        Read the full briefing first: \(url)
        It has my handwritten notes, what was being said when I wrote each one, and the speaker-labelled transcript.

        Pull out the decisions, action items (with owners and due dates), and open questions. Then help me with the next steps.
        """
    }
}

struct HandoffSheet: View {
    let editor: EditorModel
    @State private var controller = HandoffController()
    @State private var showSignIn = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hand off to agent")
                    .font(Theme.serif(21, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.fieldBackground))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 18)

            switch controller.state {
            case .working(let step):
                steps(current: step)
            case .ready(let url, let prompt, let expires):
                ready(url: url, prompt: prompt, expires: expires)
            case .failed(let message):
                failed(message)
            case .needsSignIn(let message):
                signInPrompt(message)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        // Size to content (steps → result) instead of a mostly-empty form sheet.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .onAppear { controller.start(editor: editor) }
        .onDisappear { controller.cancel() }
    }

    private func steps(current: HandoffController.Step) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(HandoffController.Step.allCases, id: \.self) { step in
                HStack(spacing: 12) {
                    ZStack {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if step == current {
                            ProgressView().controlSize(.small).tint(Theme.textSecondary)
                        } else {
                            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 16, height: 16)
                        }
                    }
                    .frame(width: 22)
                    Text(step.label)
                        .font(.system(size: 15, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue <= current.rawValue ? Theme.textPrimary : Theme.textTertiary)
                }
            }
        }
    }

    private func ready(url: String, prompt: String, expires: Date?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copied — paste it into any agent")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Claude, ChatGPT, Claude Code, Codex…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ScrollView {
                Text(prompt)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: 190)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.noteList))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

            HStack(spacing: 10) {
                actionButton("Copy Again", systemImage: "doc.on.doc", primary: true) { controller.copy(prompt) }
                actionButton("Copy Link", systemImage: "link") { controller.copy(url) }
                ShareLink(item: prompt) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(Theme.fieldBackground))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            if let expires {
                Text("Anyone with the link can read this note until \(expires.formatted(.dateTime.month(.abbreviated).day())). It updates if speakers are identified later.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func signInPrompt(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            actionButton("Sign In", systemImage: "person.crop.circle", primary: true) { showSignIn = true }
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            if AccountManager.shared.isSignedIn { controller.start(editor: editor) }
        }) {
            SignInSheet()
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)
            actionButton("Try Again", systemImage: "arrow.clockwise", primary: true) {
                controller.start(editor: editor)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(primary ? Theme.accent : Theme.fieldBackground))
                .foregroundStyle(primary ? .white : Theme.textPrimary)
        }
        .buttonStyle(PressableStyle())
    }
}
