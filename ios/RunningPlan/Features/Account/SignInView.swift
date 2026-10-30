import SwiftUI

/// Email sign-in, shown as a sheet when Save needs an account: an email, then the 6-digit code from the email.
/// Sign in with Apple waits for the paid Apple account (backlog "Later").
struct SignInView: View {
    let model: SaveFlowModel
    @State private var email = ""
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
                    .foregroundStyle(Palette.muted.color)
                    .frame(minHeight: Metrics.minTouchTarget)
            }
            switch model.step {
            case .code(let address):
                title("Check your email", "We sent a 6-digit code to \(address). It works for 10 minutes.")
                field("6-digit code", text: $code, id: "signin.code")
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                primary("Sign in and save", id: "signin.verify", enabled: code.filter(\.isNumber).count == 6) {
                    await model.verify(code: code)
                }
                Button("Use a different email") {
                    code = ""
                    model.useDifferentEmail()
                }
                .foregroundStyle(Palette.accentText.color)
                .frame(minHeight: Metrics.minTouchTarget)
            default:
                title("Save your plan", "Enter your email and we'll send you a code to sign in. No password needed.")
                field("name@example.com", text: $email, id: "signin.email")
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                primary("Send code", id: "signin.send", enabled: !email.isEmpty) {
                    await model.sendCode(email: email)
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 15)).foregroundStyle(Palette.amberText.color).accessibilityIdentifier("signin.error")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // A container keeps its children's own identifiers; without it every child would take this one.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.signin")
        .onAppear { focused = true }
        .onChange(of: model.step) { focused = true }
    }

    private func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.system(size: 28, weight: .bold)).foregroundStyle(Palette.ink.color).accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 16)).foregroundStyle(Palette.muted.color)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, id: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.muted.color))
            .font(.system(size: 18))
            .foregroundStyle(Palette.ink.color)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 14))
            .focused($focused)
            .accessibilityIdentifier(id)
    }

    private func primary(_ label: String, id: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            ZStack {
                Text(label).opacity(model.busy ? 0 : 1)
                if model.busy { ProgressView().tint(.white) }
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
        }
        .disabled(!enabled || model.busy)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}
