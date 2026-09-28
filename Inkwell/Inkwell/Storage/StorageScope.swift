import Foundation

/// Where this iPad keeps a set of notes. Each signed-in account gets its own SwiftData store
/// and files, so one person's notes are never even loaded while someone else is signed in
/// (a per-row owner filter would leak through any query that forgot it). `.device` holds
/// notes made while signed out, at the app's original locations, so existing installs open
/// offline with no migration.
nonisolated enum StorageScope: Equatable, Hashable, Sendable {
    case device
    case account(String)            // Neon Auth user id, lowercase

    var id: String {
        switch self {
        case .device: "device"
        case .account(let uid): "account-\(uid)"
        }
    }

    var accountID: String? {
        if case .account(let uid) = self { return uid }
        return nil
    }

    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var accountsRoot: URL { support.appendingPathComponent("Accounts", isDirectory: true) }

    var directory: URL {
        switch self {
        case .device: Self.support
        case .account(let uid): Self.accountsRoot.appendingPathComponent(uid, isDirectory: true)
        }
    }

    /// `.device` keeps SwiftData's default store name so pre-accounts installs open unchanged.
    var storeURL: URL {
        directory.appendingPathComponent(self == .device ? "default.store" : "Inkwell.store")
    }
    var notesRoot: URL { directory.appendingPathComponent("Notes", isDirectory: true) }
    var manifestURL: URL { directory.appendingPathComponent("backup-manifest.json") }

    // MARK: The scope the app is using right now (read from any thread).

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: StorageScope = .device
    static var current: StorageScope {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }
}
