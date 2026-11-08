import APIClient
import Testing
@testable import RunningPlan

/// How a proposal reads on its card (DK-Review, docs/design-notes.md "Proposal card").
struct ProposalCardModelTests {
    private func card(_ proposal: Components.Schemas.Proposal, revision: Int? = 3) -> ProposalCardModel {
        ProposalCardModel(proposal: proposal, planContentRevision: revision)
    }

    @Test func theBoardsProposal() throws {
        let model = card(try ReviewFixture.proposal())

        #expect(model.title == "Ease Saturday's long run")
        #expect(model.reason == "Your last two long runs felt harder than planned. A slightly shorter one lets you finish feeling strong.")
        #expect(model.rows.count == 1)
        let row = try #require(model.rows.first)
        #expect(row.day == "Sat, Oct 31")
        #expect(row.before == "8 km")
        #expect(row.after == "7 km")
        #expect(!row.locked)
        #expect(!model.stale)
    }

    @Test func aDroppedSessionHasNoAfter() throws {
        let drop = ReviewFixture.change("delete", id: ReviewFixture.tempoID, date: "2026-10-28", type: "tempo", title: "Tempo run", before: 6000, after: nil)
        let model = card(try ReviewFixture.proposal(urgent: true, changes: [drop]))

        #expect(model.title == "Drop Wednesday's tempo run")
        #expect(model.urgent)
        #expect(model.rows.first?.before == "6 km")
        #expect(model.rows.first?.after == nil)
        #expect(model.rows.first?.dropped == true)
    }

    @Test func aHardSessionReplacedByAnEasyRunSaysSo() throws {
        let swap = ReviewFixture.change(id: ReviewFixture.tempoID, date: "2026-10-28", type: "tempo", title: "Tempo run", before: 6000, after: 4200, afterType: "easy", afterTitle: "Easy run")
        let model = card(try ReviewFixture.proposal(urgent: true, changes: [swap]))

        #expect(model.title == "Swap Wednesday's tempo run for an easy run")
        #expect(model.rows.first?.before == "Tempo run · 6 km")
        #expect(model.rows.first?.after == "Easy run · 4.2 km")
    }

    @Test func severalChangesGetOneTitleAndAtMostFiveRows() throws {
        let changes = (0..<8).map {
            ReviewFixture.change(id: "00000000-0000-4000-8000-00000000010\($0)", date: "2026-11-0\($0 + 1)", type: "easy", title: "Easy run", before: 5000, after: 4250)
        }
        let model = card(try ReviewFixture.proposal(changes: changes))

        #expect(model.title == "Ease the week ahead")
        #expect(model.rows.count == ProposalCardModel.maxRows)
        #expect(model.moreCount == 3)
    }

    @Test func aSmallProgressionAddsALittle() throws {
        let second = ReviewFixture.change(id: "00000000-0000-4000-8000-000000000020", date: "2026-11-02", type: "easy", title: "Easy run", before: 5000, after: 5250)
        let up = [ReviewFixture.change(before: 8000, after: 8400), second]
        #expect(card(try ReviewFixture.proposal(changes: up)).title == "Add a little to the week ahead")
        #expect(card(try ReviewFixture.proposal(changes: [ReviewFixture.change(before: 8000, after: 8400)])).title == "Add to Saturday's long run")
    }

    @Test func aUserOwnedSessionIsShownLockedUntilIncluded() throws {
        let mine = ReviewFixture.change(id: "00000000-0000-4000-8000-000000000021", date: "2026-11-01", type: "custom", title: "Cycling", before: 0, after: 0, userOwned: true)
        let model = card(try ReviewFixture.proposal(changes: [ReviewFixture.change(), mine]))

        #expect(model.lockedCount == 1)
        let locked = try #require(model.rows.first { $0.locked })
        #expect(locked.lockedText == "Sunday cycling is yours")
        #expect(!model.changesNothing(includeUserOwned: false))

        let onlyMine = card(try ReviewFixture.proposal(changes: [mine]))
        #expect(onlyMine.changesNothing(includeUserOwned: false))
        #expect(!onlyMine.changesNothing(includeUserOwned: true))
    }

    @Test func aProposalIsStaleOnceThePlanRevisionMovesOn() throws {
        let proposal = try ReviewFixture.proposal(base: 3)
        #expect(!card(proposal, revision: 3).stale)
        #expect(card(proposal, revision: 4).stale)
        #expect(card(try ReviewFixture.proposal(base: 3, status: "stale"), revision: 3).stale)
        #expect(!card(proposal, revision: nil).stale, "no plan loaded: nothing to compare with")
    }

    @Test func anInterviewRerunNamesTheNewPlan() throws {
        let rerun = try ReviewFixture.proposal(
            kind: "interview_rerun", reason: "A new plan for the weeks ahead from your new answers.",
            changes: [ReviewFixture.change(before: 8000, after: 9000)], planChanges: #"{"weekCount":12,"goal":{"type":"10k","date":"2027-01-10"}}"#
        )
        let model = card(rerun)

        #expect(model.title == "Re-plan the weeks ahead")
        #expect(model.isRerun)
        #expect(model.planNote == "10K on Jan 10 · 12 weeks in total")
    }

    @Test func aRerunWithManyDropsAndAdditionsShowsBothAndCountsEach() throws {
        func id(_ prefix: Int, _ n: Int) -> String { "00000000-0000-4000-8000-\(prefix)\(String(format: "%011d", n))" }
        func date(_ n: Int) -> String { "2026-11-\(String(format: "%02d", n + 1))" }
        let drops = (0..<20).map { ReviewFixture.change("delete", id: id(1, $0), date: date($0), type: "easy", title: "Easy run", before: 5000, after: nil) }
        let adds = (0..<20).map { ReviewFixture.change("create", id: id(2, $0), date: date($0), type: "easy", title: "Easy run", before: nil, after: 6000) }
        let model = card(try ReviewFixture.proposal(kind: "interview_rerun", changes: drops + adds))

        #expect(model.rows.count == ProposalCardModel.maxRows)
        #expect(model.rows.contains { $0.added })
        #expect(model.rows.contains { $0.dropped })
        #expect(model.moreCount == 35)
        #expect(model.moreText == "and 35 more (18 added, 17 dropped)")
    }

    @Test func aRerunsGoalLineSaysTheLengthIsInTotal() throws {
        let rerun = try ReviewFixture.proposal(kind: "interview_rerun", changes: [ReviewFixture.change(before: 8000, after: 9000)], planChanges: #"{"weekCount":10,"goal":{"type":"10k","date":"2026-12-31"}}"#)
        #expect(card(rerun).planNote == "10K on Dec 31 \u{00B7} 10 weeks in total")
    }
}
