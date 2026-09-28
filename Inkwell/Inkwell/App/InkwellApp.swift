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
    let container: ModelContainer
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DemoSeeder.resetStoreIfRequested()
        #endif
        let schema = Schema([Subject.self, SubjectDivider.self, Note.self, Recording.self, PageElement.self])
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            fatalError("Could not open the Inkwell store: \(error)")
        }
        self.container = container
        let context = container.mainContext
        context.autosaveEnabled = true
        #if DEBUG
        DemoSeeder.seedIfRequested(context: context)
        HandoffTestSeed.seedIfRequested(context: context)
        #endif
        AudioRecorder.recoverOrphans(context: context)
        AudioMaintenance.sweep(context: context)
        BackupEngine.shared.attach(context: context)
        SpeakerDetection.shared.attach(context: context)
        BackupUploader.shared.reconnect()
        Self.bootstrapBackupCredentials()
        AppModel.purgeRecentlyDeleted(context: context)
        _model = State(initialValue: AppModel(context: context))
    }

    /// The backup token can be handed to the app once at launch through the environment
    /// (`INKWELL_BOOTSTRAP_TOKEN`, e.g. `devicectl … --environment-variables`), so it never
    /// lives in source, the binary, or git. It's stored in the Keychain and ignored afterwards.
    private static func bootstrapBackupCredentials() {
        let env = ProcessInfo.processInfo.environment
        if let token = env["INKWELL_BOOTSTRAP_TOKEN"], !token.isEmpty, Keychain.read(BackupEngine.tokenKey) != token {
            Keychain.write(BackupEngine.tokenKey, token)
        }
        if let url = env["INKWELL_BOOTSTRAP_URL"], !url.isEmpty { AppSettings.shared.backupURL = url }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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
                            NSLog("[SPK] backupURL=%@ keychainToken=%@ isConfigured=%@",
                                  AppSettings.shared.backupURL,
                                  (Keychain.read(BackupEngine.tokenKey)?.isEmpty == false) ? "present" : "MISSING",
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
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                model.editor?.flush()
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
                Button("New Note") { model.createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
