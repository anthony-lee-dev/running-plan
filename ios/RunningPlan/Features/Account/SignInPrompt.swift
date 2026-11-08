import Observation
import SwiftUI

private struct RequestSignInKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Asks `RootView` to show the sign-in sheet (closing any full-screen cover first). Set once at the root, so every
    /// screen, cover and sheet below it can offer "Sign in" without being handed a closure.
    var requestSignIn: @MainActor () -> Void {
        get { self[RequestSignInKey.self] }
        set { self[RequestSignInKey.self] = newValue }
    }
}

/// Counts sign-ins done through `SignInModel`. Part of the keys that reload Next, Progress, the review, the inbox and the
/// watch, so they look again even when the plan is the same one (a token the server had revoked, signed in again).
@MainActor
@Observable
final class AccountChanges {
    private(set) var count = 0
    func signedIn() { count += 1 }
}

/// Every "signed out" sentence starts with this, so a screen can tell one apart and offer the way back in.
enum SignedOutMessage {
    static let prefix = "You've been signed out."

    static func matches(_ message: String?) -> Bool {
        message?.hasPrefix(prefix) == true
    }
}

/// "Sign in" for the signed-out empty states (Next, Plan, Progress, Goal), under "Set a goal".
struct SignInLink: View {
    @Environment(\.requestSignIn) private var requestSignIn

    var body: some View {
        Button(action: requestSignIn) {
            Text("Sign in")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accentText.color)
                .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("account.signin")
    }
}

/// Under a "You've been signed out. Sign in again to ..." message: the button that does it. Nothing for other messages.
struct SignInAgainButton: View {
    let message: String?
    @Environment(\.requestSignIn) private var requestSignIn

    var body: some View {
        if SignedOutMessage.matches(message) {
            Button(action: requestSignIn) {
                Text("Sign in again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accentText.color)
                    .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("account.signin")
        }
    }
}
