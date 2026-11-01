import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .initial
    @State private var plans: PlanStore
    @State private var inbox: InboxStore
    @State private var showInbox = false
    @State private var watchSync = WatchSyncModel()
    @State private var showOnboarding = false
    /// A session's spec sheet, over the tabs.
    @State private var openSession: SessionRoute?
    /// The editor for a new session, or the move sheet.
    @State private var sheet: SessionRoute?

    init() {
        let plans = PlanStore(
            loader: APIPlanLoader(client: APIConfiguration.liveSignedInClient()),
            account: APIConfiguration.liveSession,
            writer: APISessionWriter(client: APIConfiguration.liveSignedInClient())
        )
        _plans = State(initialValue: plans)
        _inbox = State(initialValue: InboxStore(service: APIInboxService(client: APIConfiguration.liveSignedInClient()), health: LiveHealthImporter(), plans: plans))
    }

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
        .task(id: plans.plan?.value1.value1.id) {
            // The count on Next's inbox card; the inbox screen shows any error itself.
            if plans.plan != nil { await inbox.refresh() }
        }
        .task(id: watchWindowKey) {
            guard let plan = plans.plan else { return }
            await watchSync.resync(sessions: plan.value2.sessions, today: PreviewViewModel.localToday())
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow(dependencies: .live, onClose: { showOnboarding = false }, onSaved: { id in
                showOnboarding = false
                Task { await plans.show(planId: id) }
            })
        }
        .fullScreenCover(isPresented: $showInbox) {
            InboxScreen(store: inbox, onClose: { showInbox = false })
        }
        .fullScreenCover(item: $openSession) { route in
            if case .open(let id) = route {
                SessionScreen(plans: plans, sessionId: id, watchSync: watchSync, inbox: inbox, onClose: { openSession = nil })
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
    /// Changes when the sessions kept on the watch change, so the schedule is refreshed then and not on every edit.
    var watchWindowKey: String {
        guard let plan = plans.plan else { return "" }
        let today = PreviewViewModel.localToday()
        return today + WatchSync.window(sessions: plan.value2.sessions, today: today).map(\.key).joined(separator: ",")
    }

    @ViewBuilder func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .next:
            NextScreen(
                plans: plans, onSetGoal: { showOnboarding = true },
                onOpen: { openSession = .open(sessionId: $0) }, onMove: { sheet = .move(sessionId: $0) },
                inboxCount: inbox.count, onInbox: { showInbox = true }
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
