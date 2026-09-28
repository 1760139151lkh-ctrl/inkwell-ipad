import SwiftUI
import SwiftData

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iPadOS relaunched us to deliver background audio-upload events.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackupUploader.backgroundID else { return completionHandler() }
        BackupUploader.shared.setBackgroundCompletion(completionHandler)
        BackupUploader.shared.reconnect()
    }
}

@main
struct InkwellApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var accounts = AccountManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DemoSeeder.resetStoreIfRequested()
        #endif
        Self.bootstrapLegacyToken()
        // Opens the signed-in account's notes (or this iPad's) with no network needed.
        AccountManager.shared.start()
        BackupUploader.shared.reconnect()
    }

    private var model: AppModel? { accounts.session?.model }

    /// Pre-accounts builds took a shared backup token through the launch environment
    /// (`INKWELL_BOOTSTRAP_TOKEN`). It's kept only so the first sign-in can claim that backup.
    private static func bootstrapLegacyToken() {
        let env = ProcessInfo.processInfo.environment
        if let token = env["INKWELL_BOOTSTRAP_TOKEN"], !token.isEmpty, AuthClient.storedUser == nil,
           Keychain.read(BackupEngine.legacyTokenKey) != token {
            Keychain.write(BackupEngine.legacyTokenKey, token)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = accounts.session {
                    SessionRoot(session: session)
                        .id(session.scope.id)
                } else {
                    SwitchingView(message: accounts.switchingMessage)
                }
            }
            .environment(accounts)
            .alert("Account", isPresented: Binding(get: { accounts.alert != nil }, set: { if !$0 { accounts.alert = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accounts.alert ?? "")
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                model?.editor?.flush()
            }
            if phase == .background { BackupEngine.shared.appDidEnterBackground() }
            if phase == .active {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await BackupEngine.shared.backUpNow()
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model?.createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// One account's library/editor, on that account's store.
private struct SessionRoot: View {
    let session: AppSession
    private var model: AppModel { session.model }

    var body: some View {
        RootView()
                .environment(model)
                .modelContainer(session.container)
                .onAppear {
                    #if DEBUG
                    if DemoSeeder.env["INKWELL_SCREEN"] != nil {
                        DemoSeeder.applyLaunchState(model: model)
                    } else {
                        model.restoreLastNote()
                        DemoSeeder.addDemoCall(context: model.context)   // INKWELL_ADD_CALL=1, additive only
                    }
                    #else
                    model.restoreLastNote()
                    #endif
                    // Diagnostic: INKWELL_DIARIZE_DEMO=1 diarizes the bundled demo call on this
                    // device and logs the accuracy and timing. Touches no notes.
                    DiarizationSelfTest.runIfRequested()
                    // Diagnostic: INKWELL_IDENTIFY_NOW=1 fires Identify Speakers on the most recent
                    // recording of the open note at launch, so the flow can be exercised without
                    // tapping the device.
                    if ProcessInfo.processInfo.environment["INKWELL_IDENTIFY_NOW"] == "1" {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            NSLog("[SPK] --- INKWELL_IDENTIFY_NOW ---")
                            NSLog("[SPK] engine=%@ detectSpeakers=%@ available=%@",
                                  AppSettings.shared.speakerEngine.rawValue,
                                  AppSettings.shared.detectSpeakers ? "on" : "OFF",
                                  SpeakerDetection.shared.isAvailable ? "yes" : "NO")
                            NSLog("[SPK] apiURL=%@ signedIn=%@ isConfigured=%@",
                                  AppConfig.apiURL?.absoluteString ?? "nil",
                                  AccountManager.shared.isSignedIn ? "yes" : "NO",
                                  BackupEngine.shared.isConfigured ? "yes" : "NO")
                            guard let ed = model.editor else { NSLog("[SPK] no editor/note open"); return }
                            let recs = ed.note.recordings.sorted { $0.startedAt > $1.startedAt }
                            NSLog("[SPK] note=%@ recordings=%d", ed.note.title, recs.count)
                            guard let rec = recs.first else { NSLog("[SPK] no recordings on this note"); return }
                            NSLog("[SPK] firing on '%@' (%@)", rec.name, rec.id.uuidString)
                            ed.identifySpeakers(rec)
                        }
                    }
                }
    }
}

/// Shown for the second or two while one account's store closes and another opens.
private struct SwitchingView: View {
    let message: String?
    var body: some View {
        ZStack {
            Theme.noteList.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                if let message {
                    Text(message).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
