import SwiftUI

/// Stand-in for a tab until its screen task lands (see docs/backlog.md).
struct PlaceholderScreen: View {
    let tab: AppTab
    @State private var showInterview = false

    var body: some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(tab.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier(tab.screenIdentifier)
                if tab == .next {
                    // Empty state of Next (docs/design-notes.md): a way into the interview until the preview lands.
                    Button("Set a goal") { showInterview = true }
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 28)
                        .frame(minHeight: 56)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
            }
        }
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .fullScreenCover(isPresented: $showInterview) {
            OnboardingFlow(dependencies: .live, onClose: { showInterview = false })
        }
    }
}
