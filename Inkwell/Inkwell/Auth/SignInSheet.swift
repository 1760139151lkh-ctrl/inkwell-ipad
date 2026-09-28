import SwiftUI
import SwiftData

/// Email → 6-digit code → signed in. The same two steps create an account the first time.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    private var accounts: AccountManager { .shared }

    private enum Step { case email, code, finishing }
    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resendAt = Date.distantPast
    @State private var localNotes = 0
    @FocusState private var focused: Bool

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var emailLooksValid: Bool {
        let e = trimmedEmail
        guard let at = e.firstIndex(of: "@") else { return false }
        return e[e.index(after: at)...].contains(".") && !e.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(step == .code ? "Check your email" : "Sign in to Inkwell")
                    .font(Theme.serif(22, weight: .bold))
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
                .disabled(step == .finishing)
            }
            .padding(.bottom, 8)

            switch step {
            case .email: emailStep
            case .code: codeStep
            case .finishing: finishing
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .interactiveDismissDisabled(step == .finishing)
        .task(id: step) {
            // The new step's field appears after this runs; focus it once it's on screen.
            try? await Task.sleep(for: .milliseconds(350))
            focused = step != .finishing
        }
        .onAppear {
            focused = true
            if accounts.user == nil {
                localNotes = (try? context.fetchCount(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))) ?? 0
            }
            if let u = accounts.user, accounts.needsReauth { email = u.email }
        }
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back up your notes and open them on any iPad. We’ll email you a code — no password.")
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            field {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit { Task { await sendCode() } }
            }
            primaryButton("Continue", enabled: emailLooksValid) { await sendCode() }
            if localNotes > 0 {
                Text("The \(localNotes) note\(localNotes == 1 ? "" : "s") on this iPad will move into your account.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 6)
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter the 6-digit code sent to \(trimmedEmail).")
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textSecondary)
            field {
                TextField("123456", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .focused($focused)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        if digits.count == 6, !busy { Task { await verify() } }
                    }
            }
            primaryButton("Sign In", enabled: code.count == 6) { await verify() }
            HStack(spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let wait = Int(resendAt.timeIntervalSince(ctx.date).rounded(.up))
                    Button(wait > 0 ? "Resend code (\(wait)s)" : "Resend code") { Task { await sendCode() } }
                        .disabled(wait > 0 || busy)
                }
                Button("Use a different email") {
                    step = .email; code = ""; error = nil
                }
                .disabled(busy)
            }
            .font(.system(size: 13.5, weight: .medium))
            .buttonStyle(.borderless)
        }
        .padding(.top, 6)
    }

    private var finishing: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(accounts.switchingMessage ?? "Signing in…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: Actions

    private func sendCode() async {
        guard emailLooksValid, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AuthClient.shared.sendCode(to: trimmedEmail)
            resendAt = Date().addingTimeInterval(30)
            code = ""
            step = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard code.count == 6, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let user = try await AuthClient.shared.verify(email: trimmedEmail, code: code)
            step = .finishing
            try await accounts.didSignIn(user)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            step = accounts.isSignedIn ? .finishing : (error is AuthClient.AuthError ? .code : .email)
            if step == .code { code = "" }
        }
    }

    // MARK: Pieces

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fieldBackground))
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            ZStack {
                if busy { ProgressView().tint(.white) } else { Text(title).font(.system(size: 15.5, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accent.opacity(enabled ? 1 : 0.4)))
            .foregroundStyle(.white)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled || busy)
    }
}
