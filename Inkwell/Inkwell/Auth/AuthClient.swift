import Foundation

/// Neon Auth (Managed Better Auth) over its REST API — there is no Swift SDK.
///
/// Sign-in is a 6-digit code sent to your email: no password to create or forget, and the
/// code proves the address is yours. The session is Better Auth's signed session cookie
/// (7 days, sliding), kept in the Keychain and presented as a `Cookie` header — Managed
/// Auth doesn't accept it as a bearer token. Every API call carries a short-lived (15 min)
/// JWT minted from it and cached in memory.
actor AuthClient {
    static let shared = AuthClient()

    struct User: Codable, Sendable, Equatable {
        var id: String          // Neon Auth user id (uuid, lowercase)
        var email: String
        var name: String?
    }

    enum AuthError: LocalizedError, Equatable {
        case notConfigured
        case invalidCode
        case codeExpired
        case tooManyAttempts
        case sessionExpired
        case network(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Sign-in isn’t available in this build."
            case .invalidCode: "That code isn’t right. Check the email and try again."
            case .codeExpired: "That code has expired. Send a new one."
            case .tooManyAttempts: "Too many attempts. Wait a minute, then send a new code."
            case .sessionExpired: "Your sign-in has expired. Sign in again to keep backing up."
            case .network(let m): m
            case .server(let m): m
            }
        }
    }

    /// "<cookie name>=<signed value>"
    private static let sessionKey = "inkwell.auth.session"
    private static let userKey = "inkwell.auth.user"

    /// The account this iPad is signed in to, readable without the network.
    nonisolated static var storedUser: User? {
        Keychain.read(userKey).flatMap { try? JSONDecoder().decode(User.self, from: Data($0.utf8)) }
    }
    nonisolated static var hasSession: Bool { Keychain.read(sessionKey)?.isEmpty == false }

    private var jwt: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    /// Bumped on sign-out: a refresh that was in flight must not restore the old session.
    private var generation = 0

    /// No cookies: a native client authenticates with bearer tokens only, and a stored
    /// cookie would make Better Auth apply browser CSRF rules to our requests.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    // MARK: Sign in

    func sendCode(to email: String) async throws {
        _ = try await post("email-otp/send-verification-otp", ["email": email, "type": "sign-in"])
    }

    /// Verifies the emailed code. Creates the account on first sign-in.
    func verify(email: String, code: String) async throws -> User {
        let (json, http) = try await post("sign-in/email-otp", ["email": email, "otp": code])
        guard let token = Self.sessionCookie(in: http), let u = json["user"] as? [String: Any], let id = u["id"] as? String else {
            throw AuthError.server("Sign-in didn’t return a session. Try again.")
        }
        let user = User(id: id.lowercased(), email: (u["email"] as? String) ?? email,
                        name: (u["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        // Only the session is saved here. The account is remembered (`remember`) once this
        // iPad's notes have been handed to it, so a crash in between can't hide them.
        generation += 1
        Keychain.write(Self.sessionKey, token)
        jwt = nil
        return user
    }

    /// Marks this iPad as signed in to `user` (read at launch, offline).
    func remember(_ user: User) throws {
        Keychain.write(Self.userKey, String(decoding: try JSONEncoder().encode(user), as: UTF8.self))
    }

    /// The JWT, but only while `userID` is still the signed-in account — work started for
    /// one account can't carry on as another after a switch.
    func accessToken(for userID: String, forceRefresh: Bool = false) async throws -> String {
        guard Self.storedUser?.id == userID else { throw AuthError.sessionExpired }
        let token = try await accessToken(forceRefresh: forceRefresh)
        guard Self.storedUser?.id == userID else { throw AuthError.sessionExpired }
        return token
    }

    // MARK: Sign in with Google

    /// The one-time start of a Google sign-in: where to send the browser, and the challenge
    /// cookie that must accompany the verifier when it comes back.
    struct GoogleStart: Sendable { var url: URL; var challengeCookie: String }

    /// Neon Auth runs the Google OAuth (PKCE) and returns to our Function's /auth/callback,
    /// which hands a one-time verifier to inkwell://auth-callback.
    func startGoogle() async throws -> GoogleStart {
        guard let base = AppConfig.authURL, let api = AppConfig.apiURL else { throw AuthError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("sign-in/social"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "google",
            "callbackURL": api.appendingPathComponent("auth/callback").absoluteString,
            "errorCallbackURL": api.appendingPathComponent("auth/callback").absoluteString,
            "disableRedirect": true,
        ] as [String: Any])
        let (data, http) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw Self.mapError(status: http.statusCode, json: json) }
        guard let s = json["url"] as? String, let url = URL(string: s), url.scheme == "https" else {
            throw AuthError.server("Google sign-in isn’t available right now.")
        }
        let challenge = Self.cookies(in: http).filter { $0.name.contains("session_chall") }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !challenge.isEmpty else { throw AuthError.server("Google sign-in couldn’t start. Try again.") }
        return GoogleStart(url: url, challengeCookie: challenge)
    }

    /// Redeems the verifier from inkwell://auth-callback for a session.
    func finishGoogle(verifier: String, start: GoogleStart) async throws -> User {
        guard let base = AppConfig.authURL else { throw AuthError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent("get-session"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "neon_auth_session_verifier", value: verifier)]
        var req = URLRequest(url: comps.url!)
        req.setValue(start.challengeCookie, forHTTPHeaderField: "Cookie")
        let (data, http) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw Self.mapError(status: http.statusCode, json: json) }
        guard let token = Self.sessionCookie(in: http), let u = json["user"] as? [String: Any], let id = u["id"] as? String else {
            throw AuthError.server("Google sign-in didn’t finish. Try again.")
        }
        generation += 1
        Keychain.write(Self.sessionKey, token)
        jwt = nil
        return User(id: id.lowercased(), email: (u["email"] as? String) ?? "",
                    name: (u["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Tokens

    /// A JWT for the Inkwell API, refreshed a minute before it expires. Concurrent callers
    /// share one refresh.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let jwt, jwt.expires.timeIntervalSinceNow > 60 { return jwt.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.mintJWT() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func mintJWT() async throws -> String {
        guard let base = AppConfig.authURL else { throw AuthError.notConfigured }
        guard let sessionToken = Keychain.read(Self.sessionKey), !sessionToken.isEmpty else { throw AuthError.sessionExpired }
        let gen = generation
        var req = URLRequest(url: base.appendingPathComponent("token"))
        req.setValue(sessionToken, forHTTPHeaderField: "Cookie")
        let (data, http) = try await send(req)
        guard gen == generation else { throw AuthError.sessionExpired }   // signed out meanwhile
        if http.statusCode == 401 || http.statusCode == 403 {
            // The session was revoked or expired server-side. Notes stay usable; backup pauses.
            Keychain.write(Self.sessionKey, "")
            jwt = nil
            throw AuthError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw AuthError.server("Couldn’t refresh your sign-in (\(http.statusCode)).")
        }
        // Better Auth slides the session forward on use and may re-issue the cookie.
        if let rotated = Self.sessionCookie(in: http), rotated != sessionToken {
            Keychain.write(Self.sessionKey, rotated)
        }
        jwt = (token, Self.expiry(of: token) ?? Date().addingTimeInterval(10 * 60))
        return token
    }

    /// `exp` from a JWT payload (no verification; the server verifies).
    nonisolated static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: Sign out

    /// Ends the session on the server (best effort) and forgets it on this iPad.
    func signOut() async {
        if let base = AppConfig.authURL, let token = Keychain.read(Self.sessionKey), !token.isEmpty {
            var req = URLRequest(url: base.appendingPathComponent("sign-out"))
            req.httpMethod = "POST"
            req.setValue(token, forHTTPHeaderField: "Cookie")
            req.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin")   // CSRF check on cookie POSTs
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            _ = try? await send(req)
        }
        forget()
    }

    /// Clears the session and account from the Keychain (no network).
    func forget() {
        generation += 1
        refreshing = nil
        Keychain.write(Self.sessionKey, "")
        Keychain.write(Self.userKey, "")
        jwt = nil
    }

    // MARK: HTTP

    private func post(_ path: String, _ body: [String: String]) async throws -> ([String: Any], HTTPURLResponse) {
        guard let base = AppConfig.authURL else { throw AuthError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw Self.mapError(status: http.statusCode, json: json) }
        return (json, http)
    }

    /// The auth server's own origin — always a trusted origin for its CSRF check.
    nonisolated static func origin(of url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }

    /// "<name>=<value>" of the session cookie in a response, if it set one.
    nonisolated static func sessionCookie(in http: HTTPURLResponse) -> String? {
        cookies(in: http).first { $0.name.hasSuffix("session_token") && !$0.value.isEmpty }.map { "\($0.name)=\($0.value)" }
    }

    nonisolated static func cookies(in http: HTTPURLResponse) -> [HTTPCookie] {
        guard let url = http.url else { return [] }
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AuthError.network("No response from the sign-in server.") }
            return (data, http)
        } catch let e as AuthError {
            throw e
        } catch {
            throw AuthError.network("Can’t reach the sign-in server. Check your connection.")
        }
    }

    /// Better Auth errors look like {"code": "INVALID_OTP", "message": "…"}.
    nonisolated static func mapError(status: Int, json: [String: Any]) -> AuthError {
        let code = (json["code"] as? String ?? "").uppercased()
        let message = json["message"] as? String
        if status == 429 || code.contains("TOO_MANY") { return .tooManyAttempts }
        if code.contains("EXPIRED") { return .codeExpired }
        if code.contains("INVALID_OTP") || code.contains("INVALID_CODE") || code == "OTP_NOT_FOUND" { return .invalidCode }
        if code.contains("INVALID_EMAIL") { return .server("That doesn’t look like an email address.") }
        return .server(message.map { "\($0)." } ?? "Sign-in failed (\(status)).")
    }
}
