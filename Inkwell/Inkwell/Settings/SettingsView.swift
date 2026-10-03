import SwiftUI
import SwiftData
import Speech

enum SettingsSection: String, CaseIterable, Identifiable {
    case document, pencil, audio, backup, recentlyDeleted, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .document: "Document"
        case .pencil: "Pencil"
        case .audio: "Audio"
        case .backup: "Account"
        case .recentlyDeleted: "Recently Deleted"
        case .about: "About"
        }
    }
    var icon: String {
        switch self {
        case .document: "doc.text"
        case .pencil: "applepencil"
        case .audio: "waveform"
        case .backup: "person.crop.circle"
        case .recentlyDeleted: "trash"
        case .about: "info.circle"
        }
    }
}

/// Settings (PRD §6.10): a two-pane sheet, kept tiny on purpose.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(Theme.serif(24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                ForEach(SettingsSection.allCases) { section in
                    Button { model.settingsSection = section } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 14))
                                .frame(width: 20)
                                .foregroundStyle(Theme.textSecondary)
                            Text(section.title)
                                .font(.system(size: 15, weight: model.settingsSection == section ? .semibold : .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.settingsSection == section ? Theme.rowSelected : .clear))
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: 230)
            .background(Theme.sidebar)

            VStack(spacing: 0) {
                HStack {
                    Text(model.settingsSection.title)
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 24)
                .frame(height: 60)
                ScrollView {
                    Group {
                        switch model.settingsSection {
                        case .document: DocumentSettings()
                        case .pencil: PencilSettings()
                        case .audio: AudioSettings()
                        case .backup: BackupSettings()
                        case .recentlyDeleted: RecentlyDeletedSettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .background(Theme.noteList)
        }
        .presentationSizing(.page)
    }
}

// MARK: - Building blocks

struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sidebar))
            if let footer {
                Text(footer)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 18)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if showDivider {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

// MARK: - Document

struct DocumentSettings: View {
    @State private var showPaper = false
    private var settings: AppSettings { .shared }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(header: "New note title", footer: "Example: “\(settings.newNoteTitle())”") {
                SettingsRow(title: "Title") {
                    TextField("Note", text: $settings.defaultTitle)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                        .foregroundStyle(Theme.textSecondary)
                }
                SettingsRow(title: "Include date") { Toggle("", isOn: $settings.includeDate).labelsHidden() }
                SettingsRow(title: "Include time", showDivider: false) { Toggle("", isOn: $settings.includeTime).labelsHidden() }
            }
            SettingsGroup(header: "Default view") {
                SettingsRow(title: "View", subtitle: "Seamless scrolls continuously. Single Page snaps to one whole page at a time.",
                            showDivider: false) {
                    Picker("", selection: $settings.defaultView) {
                        ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
            SettingsGroup(header: "Default paper") {
                Button { showPaper = true } label: {
                    SettingsRow(title: "Paper", subtitle: paperSummary(settings.defaultPaper), showDivider: false) {
                        PaperPreview(paper: settings.defaultPaper)
                            .frame(width: 26, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showPaper) {
            PaperSheet(initial: settings.defaultPaper, applyTitle: "Done") { settings.defaultPaper = $0 }
        }
    }

    private func paperSummary(_ p: Paper) -> String {
        "\(p.style.label) · \(p.color.label) · Letter · \(p.landscape ? "Landscape" : "Portrait")"
    }
}

// MARK: - Pencil

struct PencilSettings: View {
    var body: some View {
        @Bindable var settings = AppSettings.shared
        SettingsGroup(footer: "Off: only Apple Pencil draws, and fingers scroll and zoom. Turn on to draw with a finger (useful in the Simulator).") {
            SettingsRow(title: "Draw with finger", showDivider: false) {
                Toggle("", isOn: $settings.drawWithFinger).labelsHidden()
            }
        }
    }
}

// MARK: - Audio

struct AudioSettings: View {
    private var status: TranscriptionModelStatus { .shared }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(header: "Recording") {
                ForEach(RecordingQuality.allCases) { q in
                    Button { settings.recordingQuality = q } label: {
                        SettingsRow(title: q.label, subtitle: q.detail, showDivider: q != RecordingQuality.allCases.last) {
                            if settings.recordingQuality == q {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            SettingsGroup(header: "Transcription",
                          footer: "Convert your recordings to text as you record, so they’re readable and searchable. Runs on this iPad; nothing leaves the device.") {
                SettingsRow(title: "Live transcription") {
                    Toggle("", isOn: $settings.liveTranscription).labelsHidden()
                }
                SettingsRow(title: "Language") {
                    Picker("", selection: $settings.transcriptionLocaleID) {
                        ForEach(localeOptions, id: \.self) { id in
                            Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.textSecondary)
                }
                SettingsRow(title: "Speech model", subtitle: modelSubtitle, showDivider: false) {
                    modelTrailing
                }
            }
            SettingsGroup(header: "Speakers", footer: speakersFooter) {
                SettingsRow(title: "Detect speakers") {
                    Toggle("", isOn: $settings.detectSpeakers).labelsHidden()
                }
                ForEach(SpeakerEngine.allCases) { engine in
                    Button { settings.speakerEngine = engine } label: {
                        SettingsRow(title: engine.label, subtitle: engine.detail,
                                    showDivider: engine != SpeakerEngine.allCases.last) {
                            if settings.speakerEngine == engine {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .task { await status.refresh() }
        .onChange(of: settings.transcriptionLocaleID) { _, _ in Task { await status.refresh() } }
    }

    private var speakersFooter: String {
        let common = "Tap a speaker’s label in the transcript to name them; names are remembered."
        switch AppSettings.shared.speakerEngine {
        case .onDevice: return "Voices are told apart by a model bundled in the app, on this iPad. " + common
        case .cloud: return "Voices are told apart on the server after a recording backs up, which requires Backup. " + common
        }
    }

    private var localeOptions: [String] {
        let ids = status.supportedLocales.map { $0.identifier(.bcp47) }
        let current = AppSettings.shared.transcriptionLocaleID
        let all = Set(ids + [current])
        return all.sorted { (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1) }
    }

    private var modelSubtitle: String {
        switch status.state {
        case .checking: "Checking…"
        case .unsupported: "Not available for this language on this iPad"
        case .notInstalled: "Not downloaded. It’s a one-time download."
        case .downloading(let p): "Downloading… \(Int(p * 100))%"
        case .installed(let engine): "Ready · \(engine)"
        case .failed(let msg): msg
        }
    }

    @ViewBuilder
    private var modelTrailing: some View {
        switch status.state {
        case .notInstalled, .failed:
            Button("Download") { Task { await status.download() } }
                .font(.system(size: 14, weight: .semibold))
        case .downloading(let p):
            ProgressView(value: p).frame(width: 80)
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            EmptyView()
        }
    }
}

// MARK: - Account & Backup

struct BackupSettings: View {
    @State private var confirmRestore = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var showSignIn = false
    @State private var working = false
    @State private var deleteError: String?
    @Query private var notes: [Note]
    private var engine: BackupEngine { .shared }
    private var accounts: AccountManager { .shared }

    private var busy: Bool {
        switch engine.phase {
        case .backingUp, .restoring: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let user = accounts.user {
                signedIn(user)
            } else {
                signedOut
            }
        }
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .alert("Restore from Backup?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore") { Task { await engine.restore() } }
        } message: {
            Text(notes.isEmpty
                 ? "Downloads every note, drawing, recording, and transcript from your backup."
                 : "Notes already on this iPad are left as they are; only missing notes are downloaded.")
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        let cloudAvailable = AppConfig.apiURL != nil && AppConfig.authURL != nil
        return SettingsGroup(footer: cloudAvailable
                      ? "Without an account, notes stay on this iPad only. When you sign in, the notes here move into your account and back up automatically."
                      : "笔记、手写和录音保存在此 iPad。请定期导出重要笔记；此版本尚未连接云备份。") {
            SettingsRow(title: cloudAvailable ? "Not signed in" : "本机笔记",
                        subtitle: cloudAvailable ? "Sign in to back up your notes and open them on your other iPads." : "离线可用 · 云备份未连接",
                        showDivider: false) {
                if cloudAvailable {
                    Button("Sign In") { showSignIn = true }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedIn(_ user: AuthClient.User) -> some View {
        SettingsGroup(header: "Account", footer: accounts.lastSignInSummary) {
            SettingsRow(title: user.email,
                        subtitle: accounts.needsReauth ? "Sign-in expired — your notes are here; backup is paused." : "Signed in",
                        showDivider: false) {
                if accounts.needsReauth {
                    Button("Sign In Again") { showSignIn = true }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .padding(.bottom, 22)

        SettingsGroup(header: "Backup", footer: "Notes back up automatically 30 seconds after you stop editing, and when you leave the app. Audio uploads after a recording stops.") {
            SettingsRow(title: "Status", subtitle: engine.statusLine) {
                if busy {
                    ProgressView()
                } else if case .failed = engine.phase {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if engine.lastBackupAt != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            SettingsRow(title: "Back Up Now") {
                Button("Back Up") { Task { await engine.backUpNow() } }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(!engine.isConfigured || busy)
            }
            SettingsRow(title: "Restore from Backup",
                        subtitle: engine.lastRestoreSummary ?? "Downloads notes from your backup that aren’t on this iPad.",
                        showDivider: false) {
                Button("Restore") { confirmRestore = true }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(!engine.isConfigured || busy)
            }
        }
        .padding(.bottom, 22)

        SettingsGroup(footer: deleteError) {
            SettingsRow(title: "Sign Out") {
                Button("Sign Out") { confirmSignOut = true }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(working || !accounts.canSwitch)
            }
            SettingsRow(title: "Delete Account", subtitle: "Permanently deletes your account and everything backed up.", showDivider: false) {
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.recordRed)
                    .disabled(working || accounts.needsReauth || !accounts.canSwitch)
            }
        }
        .confirmationDialog("Sign out of \(user.email)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out") { Task { working = true; await accounts.signOut(removeFromDevice: false) } }
            if accounts.unbackedNoteCount() == 0 && !accounts.needsReauth {
                Button("Sign Out and Remove Notes from This iPad", role: .destructive) {
                    Task { working = true; await accounts.signOut(removeFromDevice: true) }
                }
            }
        } message: {
            let pending = accounts.unbackedNoteCount()
            Text(pending > 0
                 ? "Your notes stay on this iPad and come back when you sign in again. \(pending) note\(pending == 1 ? " hasn’t" : "s haven’t") finished backing up yet."
                 : "Your notes stay on this iPad and come back when you sign in again, or you can remove them — they’re all backed up.")
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                Task {
                    working = true
                    deleteError = nil
                    do { try await accounts.deleteAccount() } catch { deleteError = error.localizedDescription }
                    working = false
                }
            }
        } message: {
            Text("This permanently deletes your account, every backed-up note, recording and transcript, and all handoff links, and removes your notes from this iPad. This can’t be undone.")
        }
    }
}

// MARK: - Recently Deleted

struct RecentlyDeletedSettings: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Note> { $0.deletedAt != nil }, sort: \Note.modifiedAt, order: .reverse) private var deleted: [Note]
    @State private var confirmPurge: Note?

    var body: some View {
        SettingsGroup(footer: "Notes are kept for 30 days, then deleted permanently.") {
            if deleted.isEmpty {
                SettingsRow(title: "No recently deleted notes", showDivider: false) { EmptyView() }
            }
            ForEach(deleted) { note in
                SettingsRow(title: note.title, subtitle: daysLeft(note), showDivider: note.id != deleted.last?.id) {
                    HStack(spacing: 14) {
                        Button("Restore") { model.restore(note) }
                        Button("Delete", role: .destructive) { confirmPurge = note }
                            .foregroundStyle(Theme.recordRed)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .confirmationDialog("Delete “\(confirmPurge?.title ?? "")” permanently?", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let n = confirmPurge { model.deletePermanently(n) }
                confirmPurge = nil
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func daysLeft(_ note: Note) -> String {
        guard let d = note.deletedAt else { return "" }
        let left = max(0, 30 - Int(Date().timeIntervalSince(d) / 86400))
        return "Deleted \(d.formatted(.dateTime.month(.abbreviated).day())) · \(left) day\(left == 1 ? "" : "s") left"
    }
}

// MARK: - About

struct AboutSettings: View {
    @State private var bytes: Int64 = 0

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Version") {
                Text(version).foregroundStyle(Theme.textSecondary)
            }
            SettingsRow(title: "Storage used", showDivider: false) {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(Theme.textSecondary)
            }
        }
        .task { bytes = await Task.detached { NoteFiles.totalBytesUsed }.value }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
