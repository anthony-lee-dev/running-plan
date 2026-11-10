import APIClient
import SwiftUI

/// The Goal tab: goal and settings (design §8.5). No DK board exists for it, so the layout is built from the board tokens:
/// the goal card, one card of settings, the account and the privacy notes, in the dark theme's cards and 44 pt rows.
struct GoalScreen: View {
    let plans: PlanStore
    let store: GoalStore
    let settings: ReviewSettingsModel
    var watchSync: WatchSyncModel?
    let isSignedIn: @Sendable () async -> Bool
    let onSetGoal: () -> Void
    /// Called when the review setting sheet closes, so the weekly review looks at the new setting.
    var onReviewSettingsClosed: () -> Void = {}
    /// Opens the list of every imported run (a cover `RootView` owns, so sign-in can close it).
    var onRuns: () -> Void = {}

    @State private var signedIn: Bool?
    @State private var showReviewSettings = false
    @State private var showWatchSettings = false
    @State private var aiSwitch = AISummarySwitch(service: APIRunSummaryService(client: APIConfiguration.liveSignedInClient()))
    @State private var showGoalEdit = false
    @State private var rerunFlow: InterviewHolder?
    @State private var showProposals = false
    @State private var confirmDeletePlan = false
    @State private var confirmDeleteAccount = false
    @State private var deletePlanError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Goal and settings")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AppTab.goal.screenIdentifier)
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .toolbarBackground(Palette.tabBar.color, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task(id: loadKey) {
            signedIn = await isSignedIn()
            if signedIn == true, case .loading = settings.state { await settings.load() }
        }
        .sheet(isPresented: $showReviewSettings, onDismiss: onReviewSettingsClosed) {
            ReviewSettingsSheet(model: settings, onClose: { showReviewSettings = false })
        }
        .sheet(isPresented: $showWatchSettings) {
            if let watchSync { WatchSettingsSheet(sync: watchSync, plans: plans, onClose: { showWatchSettings = false }) }
        }
        .sheet(isPresented: $showGoalEdit) {
            if let plan = plans.plan {
                // Rebuilt when the plan reloads (a conflict), so the sheet starts from the latest goal.
                GoalEditSheet(goal: plan.value1.value2.goal, store: store, onClose: { showGoalEdit = false })
                    .id(plan.value1.value1.revision)
            }
        }
        .sheet(isPresented: $showProposals) {
            RerunProposalsSheet(store: store, onClose: { showProposals = false })
        }
        .fullScreenCover(item: $rerunFlow) { holder in
            InterviewView(flow: holder.flow, isRerun: true, onFinish: { answers, _ in
                rerunFlow = nil
                Task { if await store.rerun(answers: answers, today: PreviewViewModel.localToday()) { showProposals = true } }
            }, onClose: { rerunFlow = nil })
        }
    }

    /// Changes when the plan or the sign-in state does, so the account part and the settings load again.
    private var loadKey: String {
        let state: String
        switch plans.state {
        case .loading: state = "loading"
        case .empty: state = "empty"
        case .loaded: state = "loaded"
        case .failed: state = "failed"
        }
        // `isSignedIn` too: signing in to an account with no plan leaves the state `.empty`, but the account card is back.
        return "\(plans.plan?.value1.value1.id ?? "-") \(state) \(plans.isSignedIn)"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch plans.state {
        case .loaded(let plan):
            goalCard(plan.value1.value2.goal)
            settingsCard
            planCard
        case .loading:
            ProgressView().tint(Palette.accentText.color).frame(maxWidth: .infinity).accessibilityLabel("Loading your plan")
        case .failed(let message):
            card {
                Text(message).font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                textButton("Try again") { Task { await plans.load() } }
            }
        case .empty:
            card {
                Text("No plan yet.").font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                Button(action: onSetGoal) {
                    Text("Set a goal")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("goal.set")
                if !plans.isSignedIn { SignInLink() }
            }
        }
        if signedIn == true { accountCard }
        privacyCard
    }

    private func goalCard(_ goal: Components.Schemas.Goal) -> some View {
        let summary = GoalModel.summary(goal)
        return card {
            Text("Your goal").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            Text(summary.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.ink.color)
                .accessibilityIdentifier("goal.title")
            Text(summary.detail).font(.system(size: 15)).foregroundStyle(Palette.goalText.color)
            Text("Editing the goal changes its date and time only. Re-running the interview plans the weeks after this one again, as a suggestion you accept or dismiss.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            if let error = store.goalError {
                Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("goal.error")
                SignInAgainButton(message: error)
            }
            HStack(spacing: 10) {
                // A plan with no goal has no date or time to edit; the interview re-run sets one.
                if goal._type != .none { pillButton("Edit goal", id: "goal.edit", filled: false) { showGoalEdit = true } }
                pillButton("Re-run the interview", id: "goal.rerun", filled: true) { startRerun() }
            }
            .disabled(store.busy)
            if store.busy { ProgressView().tint(Palette.accentText.color).accessibilityLabel("Working") }
        }
    }

    private var settingsCard: some View {
        card {
            Text("Settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            switch settings.state {
            case .loading:
                ProgressView().tint(Palette.accentText.color).frame(maxWidth: .infinity).accessibilityLabel("Loading your settings")
            case .failed(let message):
                Text(message).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                textButton("Try again") { Task { await settings.load() } }
            case .loaded(let setting):
                row("Reviews", value: GoalModel.reviewLine(setting), id: "settings.review") { showReviewSettings = true }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show targets as").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Picker("Show targets as", selection: Binding(get: { setting.targetDisplay }, set: { new in Task { await settings.choose(targetDisplay: new) } })) {
                        Text("Pace").tag(Components.Schemas.TargetDisplay.pace)
                        Text("Heart rate").tag(Components.Schemas.TargetDisplay.heart_rate)
                        Text("Effort").tag(Components.Schemas.TargetDisplay.effort)
                    }
                    .pickerStyle(.segmented)
                    .disabled(settings.saving)
                    .accessibilityIdentifier("settings.targetDisplay")
                }
                aiSummariesRow
                if let error = settings.error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("settings.error")
                    SignInAgainButton(message: error)
                }
            }
            row("Your runs", value: "All imported", id: "settings.runs", action: onRuns)
            if let watchSync, watchSync.isSupported {
                row("Apple Watch", value: watchSync.wantsSync ? "On" : "Off", id: "settings.watch") { showWatchSettings = true }
            }
        }
    }

    /// On by default; the server holds it, so the web app shares it. Off shows the plain text summary and never asks a model.
    @ViewBuilder
    private var aiSummariesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { aiSwitch.isOn ?? true }, set: { new in Task { await aiSwitch.set(new); await settings.load() } })) {
                Text("AI run summaries").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
            }
            .tint(Palette.accentText.color)
            .disabled(aiSwitch.isOn == nil || aiSwitch.saving)
            .accessibilityIdentifier("settings.aiSummaries")
            Text("Reworded by AI from your run's numbers. Off shows a plain summary and never calls AI.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            if let error = aiSwitch.error {
                Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("settings.aiSummaries.error")
            }
        }
        .task { await aiSwitch.load() }
    }

    private var planCard: some View {
        card {
            Text("Plan").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            Text("Deleting the plan removes it and all its sessions, and takes its workouts off your watch. Your imported runs stay in the inbox.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            if let deletePlanError {
                Text(deletePlanError).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("plan.delete.error")
                SignInAgainButton(message: deletePlanError)
            }
            textButton("Delete plan", id: "plan.delete", tint: Palette.accentText.color) {
                deletePlanError = nil
                confirmDeletePlan = true
            }
            .confirmationDialog("Delete this plan?", isPresented: $confirmDeletePlan, titleVisibility: .visible) {
                Button("Yes, delete it", role: .destructive) { Task { deletePlanError = await plans.deletePlan() } }
                Button("Keep plan", role: .cancel) {}
            } message: {
                Text("This removes the plan and all its sessions. You can set a new goal afterwards.")
            }
        }
    }

    private var accountCard: some View {
        card {
            Text("Account").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            if let error = store.accountError {
                Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("account.error")
                SignInAgainButton(message: error)
            }
            textButton("Sign out", id: "account.signOut") {
                Task {
                    await store.signOut()
                    settings.reset()
                    signedIn = false
                }
            }
            .disabled(store.busy)
            textButton("Delete account", id: "account.delete", tint: Palette.accentText.color) { confirmDeleteAccount = true }
                .disabled(store.busy)
                .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                    Button("Yes, delete everything", role: .destructive) {
                        Task {
                            if await store.deleteAccount() {
                                settings.reset()
                                signedIn = false
                            }
                        }
                    }
                    Button("Keep my account", role: .cancel) {}
                } message: {
                    Text("This permanently removes your plans, sessions, runs, check-ins and settings, and signs you out. It can't be undone.")
                }
        }
    }

    private var privacyCard: some View {
        card {
            Text("Privacy").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            ForEach(Self.privacyNotes, id: \.self) { note in
                Text(note).font(.system(size: 14)).foregroundStyle(Palette.goalText.color).fixedSize(horizontal: false, vertical: true)
            }
            if signedIn == true {
                switch store.export {
                case .idle:
                    exportButton
                case .working:
                    ProgressView().tint(Palette.accentText.color).accessibilityLabel("Preparing your data")
                case .ready(let url):
                    ShareLink(item: url) {
                        Text("Share your data file").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                            .frame(minHeight: Metrics.minTouchTarget, alignment: .leading).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("privacy.export.share")
                    exportButton
                case .failed(let message):
                    Text(message).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("privacy.export.error")
                    SignInAgainButton(message: message)
                    exportButton
                }
            }
        }
    }

    static let privacyNotes = [
        "Your interview answers stay on your phone until you choose to save your plan.",
        "Once saved, your plan, sessions, run summaries and check-ins are kept on our server and sent over an encrypted connection. No GPS routes are kept.",
        "The pain question is stored as a yes or no, never as free text. Health data is never used for advertising.",
    ]

    private var exportButton: some View {
        textButton("Export my data", id: "privacy.export") { Task { await store.exportData() } }
    }

    // MARK: Actions

    private func startRerun() {
        Task {
            let answers = await store.rerunAnswers(today: PreviewViewModel.localToday())
            rerunFlow = InterviewHolder(flow: answers.map { InterviewFlow(prefilledWith: $0) } ?? InterviewFlow())
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.line.color, lineWidth: 1))
    }

    private func row(_ title: String, value: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                Text(value).font(.system(size: 15)).foregroundStyle(Palette.muted.color).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func pillButton(_ title: String, id: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(filled ? Color.white : Palette.ink.color)
                .background(filled ? Palette.accent.color : Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }

    private func textButton(_ title: String, id: String? = nil, tint: Color = Palette.accentText.color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(minHeight: Metrics.minTouchTarget, alignment: .leading).contentShape(Rectangle())
        }
        .accessibilityIdentifier(id ?? title)
    }
}

/// Lets `fullScreenCover(item:)` present the interview flow, which is a reference type without an id of its own.
struct InterviewHolder: Identifiable {
    let id = UUID()
    let flow: InterviewFlow
}
