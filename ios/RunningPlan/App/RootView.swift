import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .initial
    @State private var plans: PlanStore
    @State private var inbox: InboxStore
    @State private var showInbox = false
    /// The weekly review (DK-Review): loaded here so Next can offer it, shown over the tabs.
    @State private var reviews: ReviewStore
    @State private var reviewSettings: ReviewSettingsModel
    @State private var showReview = false
    /// Loaded here, once, for Next, Plan and Progress (distance done, "On track", the Progress tab).
    @State private var progress = ProgressStore(loader: APIProgressLoader(client: APIConfiguration.liveSignedInClient()))
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
        let reviewService = APIReviewService(client: APIConfiguration.liveSignedInClient())
        _reviews = State(initialValue: ReviewStore(service: reviewService, proposals: ProposalsStore(service: reviewService, plans: plans)))
        _reviewSettings = State(initialValue: ReviewSettingsModel(service: reviewService))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                screen(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(tab == .next && reviews.isWaiting ? 1 : 0)
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
        .task(id: reviewKey) {
            // Which review Next offers; the server decides when one is due. Not while the app is away.
            guard scenePhase == .active, let plan = plans.plan else { return }
            await reviews.load(plan: plan, today: PreviewViewModel.localToday(), keepingOpen: showReview)
        }
        .task(id: progressKey) {
            guard let plan = plans.plan else { return }
            await progress.load(planId: plan.value1.value1.id, today: PreviewViewModel.localToday())
        }
        .task(id: watchKey) {
            // On launch, on a plan change and whenever the app comes to the front; the model decides what each plan
            // state means (only `.empty` clears, never loading or an error).
            guard scenePhase == .active else { return }
            let account = await APIConfiguration.liveSession.userId
            await watchSync.update(state: plans.state, account: account, today: PreviewViewModel.localToday())
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow(dependencies: .live, onClose: { showOnboarding = false }, onSaved: { id in
                showOnboarding = false
                Task { await plans.show(planId: id) }
            })
        }
        .fullScreenCover(isPresented: $showInbox) {
            InboxScreen(store: inbox, plans: plans, onClose: { showInbox = false })
        }
        .fullScreenCover(isPresented: $showReview) {
            ReviewScreen(plans: plans, review: reviews, inbox: inbox, settings: reviewSettings, onClose: { showReview = false })
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
    /// Changes when the app comes to the front, the plan loads or empties, or the sessions kept on the watch change,
    /// so the schedule is refreshed then and not on every edit.
    var watchKey: String {
        let active = scenePhase == .active ? "active" : "away"
        switch plans.state {
        case .loaded(let plan):
            let today = PreviewViewModel.localToday()
            return active + today + WatchSync.window(sessions: plan.value2.sessions, today: today, limit: watchSync.windowLimit).map(\.key).joined(separator: ",")
        case .empty: return active + "empty"
        case .loading, .failed: return active + "other"
        }
    }

    /// Changes with the plan and its content revision (every edit, import match and accepted proposal moves it), the local
    /// day, the app coming to the front, and the inbox or review closing, so Next's review card is looked at again.
    var reviewKey: String {
        guard let plan = plans.plan else { return "" }
        let active = scenePhase == .active ? "active" : "away"
        return "\(plan.value1.value1.id) \(plan.value1.value3.contentRevision) \(PreviewViewModel.localToday()) \(active) \(showInbox) \(showReview)"
    }

    /// Changes with the plan, the local day and any session's revision, so an edit or a match reloads progress.
    var progressKey: String {
        plans.plan.map(ProgressScreen.refreshKey) ?? ""
    }

    @ViewBuilder func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .next:
            NextScreen(
                plans: plans, progress: progress, onSetGoal: { showOnboarding = true },
                onOpen: { openSession = .open(sessionId: $0) }, onMove: { sheet = .move(sessionId: $0) },
                inboxCount: inbox.count, onInbox: { showInbox = true }, review: reviews, onReview: { showReview = true }, watchSync: watchSync
            )
        case .plan:
            PlanScreen(
                plans: plans, progress: progress, onSetGoal: { showOnboarding = true },
                onOpen: { openSession = .open(sessionId: $0) }, onAdd: { sheet = .add(date: $0) }
            )
        case .progress: ProgressScreen(plans: plans, store: progress, onSetGoal: { showOnboarding = true })
        default: PlaceholderScreen(tab: tab)
        }
    }
}

#Preview {
    RootView()
}
