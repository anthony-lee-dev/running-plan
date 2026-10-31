import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .initial
    @State private var plans = PlanStore(
        loader: APIPlanLoader(client: APIConfiguration.liveSignedInClient()),
        account: APIConfiguration.liveSession,
        writer: APISessionWriter(client: APIConfiguration.liveSignedInClient())
    )
    @State private var showOnboarding = false
    /// A session's spec sheet, over the tabs.
    @State private var openSession: SessionRoute?
    /// The editor for a new session, or the move sheet.
    @State private var sheet: SessionRoute?

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
        .fullScreenCover(item: $openSession) { route in
            if case .open(let id) = route {
                SessionScreen(plans: plans, sessionId: id, onClose: { openSession = nil })
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .add(let date): SessionEditor(plans: plans, date: date, onClose: { _ in sheet = nil })
            case .move(let id): MoveSheet(plans: plans, sessionId: id, onClose: { sheet = nil })
            case .open: EmptyView()
            }
        }
    }
}

@MainActor
extension RootView {
    @ViewBuilder func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .next:
            NextScreen(
                plans: plans, onSetGoal: { showOnboarding = true },
                onOpen: { openSession = .open(sessionId: $0) }, onMove: { sheet = .move(sessionId: $0) }
            )
        case .plan:
            PlanScreen(
                plans: plans, onSetGoal: { showOnboarding = true },
                onOpen: { openSession = .open(sessionId: $0) }, onAdd: { sheet = .add(date: $0) }
            )
        default: PlaceholderScreen(tab: tab)
        }
    }
}

#Preview {
    RootView()
}
