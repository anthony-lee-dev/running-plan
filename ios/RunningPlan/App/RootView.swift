import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .initial
    @State private var plans = PlanStore(
        loader: APIPlanLoader(client: APIConfiguration.liveSignedInClient()),
        account: APIConfiguration.liveSession
    )
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                screen(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .tint(Palette.accentText.color)
        .preferredColorScheme(.dark)
        .task { await plans.load() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow(dependencies: .live, onClose: { showOnboarding = false }, onSaved: { id in
                showOnboarding = false
                Task { await plans.show(planId: id) }
            })
        }
    }
}

@MainActor
extension RootView {
    @ViewBuilder func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .next: NextScreen(plans: plans, onSetGoal: { showOnboarding = true })
        default: PlaceholderScreen(tab: tab)
        }
    }
}

#Preview {
    RootView()
}
