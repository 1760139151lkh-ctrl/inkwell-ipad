import Foundation

/// Server endpoints, from build settings via Info.plist (project.yml → INKWELL_API_URL /
/// INKWELL_AUTH_URL), never hardcoded in source. A DEBUG build can be pointed at another
/// Neon branch with the same names in the launch environment.
nonisolated enum AppConfig {
    static let apiURL: URL? = url("INKWELL_API_URL", plist: "InkwellAPIURL")
    static let authURL: URL? = url("INKWELL_AUTH_URL", plist: "InkwellAuthURL")

    private static func url(_ env: String, plist: String) -> URL? {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment[env], let u = URL(string: s), u.scheme == "https" { return u }
        #endif
        guard let s = Bundle.main.object(forInfoDictionaryKey: plist) as? String,
              let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme == "https" else { return nil }
        return u
    }
}
