import AuthenticationServices
import UIKit

/// "Continue with Google": the system's secure sign-in sheet (it can use a Google account
/// already signed in to Safari) → Neon Auth → our Function's /auth/callback → back to the app
/// as inkwell://auth-callback?neon_auth_session_verifier=… (only this app's session receives it).
@MainActor final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome { case signedIn(AuthClient.User), cancelled }

    private var session: ASWebAuthenticationSession?

    func run() async throws -> Outcome {
        let start = try await AuthClient.shared.startGoogle()
        let callback: URL
        do {
            callback = try await present(start.url)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return .cancelled
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" { return .cancelled }
            throw AuthClient.AuthError.server("Google sign-in didn’t finish (\(error)).")
        }
        guard let verifier = items.first(where: { $0.name == "neon_auth_session_verifier" })?.value else {
            throw AuthClient.AuthError.server("Google sign-in didn’t finish. Try again.")
        }
        return .signedIn(try await AuthClient.shared.finishGoogle(verifier: verifier, start: start))
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("inkwell")) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin)) }
            }
            session.presentationContextProvider = self
            // Share Safari's cookies so a Google account already signed in there is one tap.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthClient.AuthError.server("Couldn’t open the Google sign-in sheet."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
