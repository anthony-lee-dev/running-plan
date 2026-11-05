import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .initial
    @State private var plans: PlanStore
    @State private var inbox: InboxStore
    @State private var showInbox = false
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
            writer: APISessionWriter(client: APIConfiguration.liveSignedInClient()),
            sync: OfflineSync(
                store: FileOfflineStore.live,
                service: APISyncService(client: APIConfiguration.liveSignedInClient()),
                // The queue belongs to one API host and one account, so another account never sends it.
                scope: { await APIConfiguration.liveSession.userId.map { "\(APIConfiguration.baseURL.absoluteString)|\($0)" } }
            )
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if plans.showsOfflineBanner { OfflineBanner() }
        }
        .sheet(item: Binding(get: { plans.conflict }, set: { _ in })) { model in
            ConflictSheet(
                model: model,
                onKeepMine: { Task { await plans.keepMine(model) } },
                onUseOther: { plans.useOtherVersion(model) }
            )
        }
        .task { await plans.load() }
        .task(id: syncKey) {
            // Edits made offline go out when the app comes to the front and whenever the queue changes, and again every
            // half minute while some wait (no network monitor: an offline attempt costs nothing).
            guard scenePhase == .active, plans.sync != nil, plans.state != .loading else { return }
            await plans.syncNow()
            while !Task.isCancelled, plans.syncWaiting {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await plans.syncNow()
            }
        }
        .task(id: plans.plan?.value1.value1.id) {
            // The count on Next's inbox card; the inbox screen shows any error itself.
            if plans.plan != nil { await inbox.refresh() }
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

    /// Changes when the app comes to the front or the number of queued edits changes.
    var syncKey: String {
        "\(scenePhase == .active)-\(plans.pendingChanges)-\(plans.state == .loading)"
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
                inboxCount: inbox.count, onInbox: { showInbox = true }, watchSync: watchSync
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
