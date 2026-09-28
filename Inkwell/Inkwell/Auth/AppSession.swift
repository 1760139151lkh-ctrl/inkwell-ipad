import Foundation
import SwiftData

/// Everything tied to one account's notes on this iPad: its SwiftData store and the
/// library/editor model on top of it. Replaced wholesale when the account changes.
@MainActor final class AppSession {
    nonisolated static let schema = Schema([Subject.self, SubjectDivider.self, Note.self, Recording.self, PageElement.self])

    #if DEBUG
    private static var seeded = false
    #endif

    let scope: StorageScope
    let container: ModelContainer
    let model: AppModel

    init(scope: StorageScope) throws {
        self.scope = scope
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
        container = try Self.openContainer(scope)
        let context = container.mainContext
        context.autosaveEnabled = true
        #if DEBUG
        // Launch-environment seeders apply to the first store opened, not every account switch.
        if !Self.seeded {
            Self.seeded = true
            DemoSeeder.seedIfRequested(context: context)
            HandoffTestSeed.seedIfRequested(context: context)
        }
        #endif
        AudioRecorder.recoverOrphans(context: context)
        AudioMaintenance.sweep(context: context)
        BackupEngine.shared.attach(context: context)
        SpeakerDetection.shared.attach(context: context)
        AppModel.purgeRecentlyDeleted(context: context)
        model = AppModel(context: context)
    }

    nonisolated static func openContainer(_ scope: StorageScope) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: scope.storeURL))
    }
}
