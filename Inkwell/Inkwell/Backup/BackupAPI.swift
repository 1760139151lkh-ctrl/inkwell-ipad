import Foundation
import CryptoKit

/// Thin client for the Neon backup Function (see server/README.md). JSON is built as
/// dictionaries so field names match the server's snake_case contract exactly.
nonisolated struct BackupAPI: Sendable {
    let baseURL: URL
    /// The signed-in account's JWT; `true` forces a fresh one (after a 401).
    let token: @Sendable (_ forceRefresh: Bool) async throws -> String

    struct APIError: LocalizedError {
        var status: Int
        var code: String
        var message: String
        var errorDescription: String? {
            if code == "session_expired" { return "Your sign-in has expired. Sign in again to keep backing up." }
            return status == 401 ? "Your account couldn’t be verified. Sign in again." : "\(message) (\(status))"
        }
        var isSessionExpired: Bool { code == "session_expired" }
        var isRetryable: Bool { status == 429 || status >= 500 || status == 0 }
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {   // thread-safe per Foundation docs
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Sends a request; retries 429/5xx/network errors with exponential backoff.
    /// JSON-encodes a request body on the caller's side (keeps non-Sendable dictionaries local).
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              headers: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 40   // the Function scales to zero; first call can be slow
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        var attempt = 0
        var refreshed = false, forceRefresh = false
        while true {
            do {
                req.setValue("Bearer \(try await bearer(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
                forceRefresh = false
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401, !refreshed {
                    // The JWT expired in flight (or the clock is off): mint a new one once.
                    refreshed = true
                    forceRefresh = true
                    continue
                }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if (200..<300).contains(status) { return json }
                let err = json["error"] as? [String: Any]
                let apiError = APIError(status: status, code: err?["code"] as? String ?? "http_\(status)",
                                        message: err?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status))
                if apiError.isRetryable && attempt < 4 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw apiError
            } catch let e as APIError {
                throw e
            } catch {
                if attempt < 3, !(error is CancellationError) {
                    attempt += 1
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw APIError(status: 0, code: "network", message: error.localizedDescription)
            }
        }
    }

    private func bearer(forceRefresh: Bool) async throws -> String {
        do {
            return try await token(forceRefresh)
        } catch let e as AuthClient.AuthError where e == .sessionExpired {
            throw APIError(status: 401, code: "session_expired", message: e.errorDescription ?? "Signed out")
        } catch let e as AuthClient.AuthError {
            throw APIError(status: 0, code: "network", message: e.errorDescription ?? "Can’t reach the sign-in server")
        }
    }

    func health() async throws -> Bool {
        let json = try await call("GET", "api/health")
        return json["ok"] as? Bool == true
    }

    // MARK: Hashing

    /// SHA-256 of a file, streamed (audio can be hundreds of MB).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
