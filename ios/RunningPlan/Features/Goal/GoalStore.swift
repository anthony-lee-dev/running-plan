import APIClient
import Foundation
import Observation

/// What the Goal and settings tab does that is not a plain setting: edit the goal, re-run the interview as a proposal,
/// export the data, sign out and delete the account. Owned by `RootView`. The review frequency and target display go
/// through `ReviewSettingsModel`, and the re-run's proposal is shown by `ProposalList` from `proposals` (a store of its own,
/// so the weekly review's list is never mixed with it).
@MainActor
@Observable
final class GoalStore {
    enum Export: Equatable {
        case idle
        case working
        /// The JSON file, ready for the share sheet.
        case ready(URL)
        case failed(String)
    }

    private(set) var export: Export = .idle
    /// A sentence for the goal card (edit, re-run).
    private(set) var goalError: String?
    /// A sentence for the account section (sign out, delete).
    private(set) var accountError: String?
    private(set) var busy = false
    let proposals: ProposalsStore

    private let service: GoalSettingsServing
    private let plans: PlanStore
    private let signOutAction: @Sendable () async -> Void
    private let exportDirectory: URL

    init(
        service: GoalSettingsServing, plans: PlanStore, proposals: ProposalsStore,
        signOut: @escaping @Sendable () async -> Void, exportDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.service = service
        self.plans = plans
        self.proposals = proposals
        self.signOutAction = signOut
        self.exportDirectory = exportDirectory
    }

    // MARK: Goal

    /// Saves a new date and target time for the goal. True when the plan now shows it.
    func editGoal(date: String?, targetSeconds: Int?) async -> Bool {
        guard let detail = plans.plan, !busy else { return false }
        busy = true
        goalError = nil
        defer { busy = false }
        let id = detail.value1.value1.id
        let goal = GoalModel.edited(detail.value1.value2.goal, date: date, targetSeconds: targetSeconds)
        do {
            plans.replace(plan: try await service.updateGoal(planId: id, revision: detail.value1.value1.revision, goal: goal))
            return true
        } catch GoalSettingsError.conflict {
            await plans.show(planId: id)
            goalError = "Your plan changed somewhere else. We've loaded the latest version; edit the goal again if you still want to."
        } catch GoalSettingsError.invalid {
            goalError = "That date or time isn't accepted. Try different ones."
        } catch is CancellationError {
            return false
        } catch {
            goalError = Self.message(for: error, action: "change your goal")
        }
        return false
    }

    /// The answers the interview starts from when it is re-run: the plan's goal and what the profile holds. Nil starts it fresh.
    func rerunAnswers(today: String) async -> InterviewAnswers? {
        guard let fields = plans.plan?.value1.value2 else { return nil }
        let profile = try? await service.profile()
        return GoalModel.answers(goal: fields.goal, interview: fields.engine?.interview, profile: profile, today: today)
    }

    /// Re-runs the interview with `answers`: the server answers with one proposal, shown by `ProposalList` and never applied
    /// by itself. True when there is a proposal to show.
    func rerun(answers: InterviewAnswers, today: String) async -> Bool {
        guard let planId = plans.plan?.value1.value1.id, !busy else { return false }
        busy = true
        goalError = nil
        defer { busy = false }
        let api: Components.Schemas.InterviewAnswers
        do {
            api = try GoalModel.apiAnswers(answers)
        } catch {
            goalError = "Those answers can't be sent. Try changing one."
            return false
        }
        if let message = await proposals.proposeInterviewRerun(planId: planId, today: today, answers: api) {
            goalError = message
            return false
        }
        return !proposals.proposals.isEmpty
    }

    // MARK: Account

    func exportData() async {
        guard export != .working else { return }
        removeExport()
        export = .working
        do {
            let data = try await service.exportAccount()
            let url = exportDirectory.appendingPathComponent("running-plan-export.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            export = .ready(url)
        } catch is CancellationError {
            export = .idle
        } catch GoalSettingsError.rateLimited {
            export = .failed("You've asked for your data a few times already. Try again in a little while.")
        } catch {
            export = .failed(Self.message(for: error, action: "export your data"))
        }
    }

    func signOut() async {
        guard !busy else { return }
        accountError = nil
        await leave()
    }

    /// Deletes the account and everything stored for it, then signs out. True when it is gone.
    func deleteAccount() async -> Bool {
        guard !busy else { return false }
        busy = true
        accountError = nil
        defer { busy = false }
        do {
            try await service.deleteAccount()
        } catch GoalSettingsError.signedOut {
            // Already signed out, so there is nothing of this account to delete from here.
        } catch is CancellationError {
            return false
        } catch {
            accountError = Self.message(for: error, action: "delete your account")
            return false
        }
        await leave()
        return true
    }

    /// Signs out and shows the signed-out state; nothing of the account stays on screen or in the temporary folder.
    private func leave() async {
        removeExport()
        export = .idle
        proposals.show([], planId: "")
        await signOutAction()
        await plans.load()
    }

    private func removeExport() {
        try? FileManager.default.removeItem(at: exportDirectory.appendingPathComponent("running-plan-export.json"))
    }

    private static func message(for error: Error, action: String) -> String {
        switch error {
        case GoalSettingsError.offline: "We couldn't reach the server. Check your connection and try again."
        case GoalSettingsError.signedOut: "You've been signed out. Sign in again to \(action)."
        case GoalSettingsError.notFound: "Your plan is no longer there."
        default: "Something went wrong when we tried to \(action). Please try again."
        }
    }
}
