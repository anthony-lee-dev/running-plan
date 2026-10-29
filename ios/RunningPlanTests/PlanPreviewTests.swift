import APIClient
import Foundation
import Testing
@testable import RunningPlan

struct PaceFormatTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(PaceFormat.minutesSeconds(390) == "6:30")
        #expect(PaceFormat.minutesSeconds(385) == "6:25")
        #expect(PaceFormat.minutesSeconds(305) == "5:05")
        #expect(PaceFormat.minutesSeconds(0) == "0:00")
    }

    @Test func formatsARangeFastestFirstWithTheUnit() {
        #expect(PaceFormat.range(min: 385, max: 430) == "6:25–7:10/km")
        #expect(PaceFormat.range(min: 345, max: 360) == "5:45–6:00/km")
    }
}

struct PlanPreviewTests {
    private func preview(_ draft: Components.Schemas.PlanDraft? = nil) throws -> PlanPreview {
        PlanPreview(draft: try draft ?? DraftFixture.draft())
    }

    @Test func headlineNamesTheGoalDateLengthAndRuns() throws {
        #expect(try preview().headline == "10K on Jan 10 · 10 weeks · 4 runs and 1 strength session a week")
    }

    @Test func headlineWithoutADateHasNoOnClause() throws {
        var draft = try DraftFixture.draft()
        draft.goal.date = nil
        #expect(PlanPreview(draft: draft).headline == "10K · 10 weeks · 4 runs and 1 strength session a week")
    }

    @Test func barsAreWeeklyKilometresWithTheirPhase() throws {
        let p = try preview()
        #expect(p.bars.map(\.kilometres) == DraftFixture.weeklyKm)
        #expect(p.bars.map(\.phase.rawValue) == DraftFixture.phases)
    }

    @Test func chartNoteNamesTheDownWeekAndTheTaper() throws {
        #expect(try preview().chartNote == "Week 5 and the final two weeks pull back so you arrive fresh.")
    }

    @Test func chartNoteListsSeveralDownWeeks() throws {
        let draft = try DraftFixture.draft(
            weeklyKm: [10, 12, 14, 12, 15, 17, 15, 18, 10, 8],
            phases: ["base", "base", "base", "build", "build", "build", "peak", "peak", "taper", "taper"]
        )
        #expect(PlanPreview(draft: draft).chartNote == "Weeks 4 and 7 and the final two weeks pull back so you arrive fresh.")
    }

    @Test func chartNoteWithOnlyATaper() throws {
        let draft = try DraftFixture.draft(weeklyKm: [10, 12, 14, 16, 12, 8], phases: ["base", "base", "build", "peak", "taper", "taper"])
        #expect(PlanPreview(draft: draft).chartNote == "The final two weeks pull back so you arrive fresh.")
    }

    @Test func chartDescriptionReadsOutTheNumbers() throws {
        #expect(try preview().chartDescription == "Bar chart of weekly running distance over 10 weeks: 16, 18, 21, 25, 20, 28, 31, 33, 24, 16 kilometres")
    }

    @Test func weekOneShowsEachDayFromTheStartDate() throws {
        let p = try preview()
        #expect(p.weekTitle == "Week 1 · 16 km")
        #expect(p.weekPhase == "Base")
        #expect(p.days.map(\.weekday) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(p.days.map(\.text) == ["Easy run · 4 km", "Strength · 20 min", "Easy run · 4 km", "Rest day", "Easy run · 3 km", "Long run · 5 km", "Rest day"])
        #expect(p.days.map(\.isRest) == [false, false, false, true, false, false, true])
    }

    @Test func sampleSessionShowsEffortPaceRangeAndDuration() throws {
        let sample = try #require(try preview().sample)
        #expect(sample.title == "Sample: Easy run, 4 km")
        #expect(sample.detail == "Easy effort · 6:25–7:10/km · about 27 min")
        #expect(sample.why == "Why: easy miles build your base without strain.")
    }

    @Test func sampleWithoutPacesShowsEffortOnly() throws {
        let p = PlanPreview(draft: try DraftFixture.draft(pace: nil))
        #expect(p.sample?.detail == "Easy effort")
    }

    @Test func assumptionsAndWarningsComeThroughAsTheServerWroteThem() throws {
        let warnings = #"[{"code":"pain_flag","severity":"caution","message":"Please talk to a qualified professional."},{"code":"goal_date_far","severity":"info","message":"Your plan starts later."}]"#
        let p = PlanPreview(draft: try DraftFixture.draft(warnings: warnings))
        #expect(p.assumptions.count == 2)
        #expect(p.assumptions[0].hasPrefix("Easy pace of 6:25–7:10/km"))
        #expect(p.warnings.map(\.code) == ["pain_flag", "goal_date_far"])
        #expect(p.warnings.map(\.isCaution) == [true, false])
    }

    @Test func kilometresDropAZeroDecimal() {
        #expect(PlanPreview.kilometres(4) == "4")
        #expect(PlanPreview.kilometres(4.5) == "4.5")
        #expect(PlanPreview.kilometres(15.96) == "16")
    }

    @Test func repeatGroupsCountTowardsDistance() throws {
        let json = #"""
        {"goal":{"type":"5k"},"startDate":"2026-11-02","weekCount":1,"source":"rules","engine":{"presetId":"5k","version":"0.1.0"},"adaptive":true,
         "weeks":[{"index":0,"phase":"base"}],"assumptions":[],"warnings":[],
         "sessions":[{"date":"2026-11-03","type":"intervals","steps":[{"kind":"warmup","goal":{"type":"distance","value":1000}},
           {"kind":"repeat","count":4,"steps":[{"kind":"work","goal":{"type":"distance","value":400}},{"kind":"recovery","goal":{"type":"distance","value":200}}]},
           {"kind":"cooldown","goal":{"type":"distance","value":1000}}]}]}
        """#
        let draft = try JSONDecoder().decode(Components.Schemas.PlanDraft.self, from: Data(json.utf8))
        #expect(PlanPreview.metres(of: draft.sessions[0]) == 4400)
        #expect(PlanPreview(draft: draft).days[1].text == "Intervals · 4.4 km")
    }

    private func decode(_ sessions: String, weekCount: Int = 1) throws -> Components.Schemas.PlanDraft {
        let json = #"{"goal":{"type":"5k"},"startDate":"2026-11-02","weekCount":\#(weekCount),"source":"rules","engine":{"presetId":"5k","version":"0.1.0"},"adaptive":true,"weeks":[],"assumptions":[],"warnings":[],"sessions":[\#(sessions)]}"#
        return try JSONDecoder().decode(Components.Schemas.PlanDraft.self, from: Data(json.utf8))
    }

    @Test func aRunSetByTimeCountsAtTheServersFallbackPace() throws {
        let draft = try decode(#"{"date":"2026-11-03","type":"easy","steps":[{"kind":"work","goal":{"type":"time","value":2520}}]}"#)
        #expect(PlanPreview.metres(of: draft.sessions[0]) == 6000)
        #expect(PlanPreview(draft: draft).days[1].text == "Easy run · 6 km")
    }

    @Test func strengthCountsForNoRunningDistance() throws {
        let draft = try decode(#"{"date":"2026-11-03","type":"strength","steps":[{"kind":"exercise","exerciseId":"plank","sets":3,"durationSec":60}]}"#)
        #expect(PlanPreview.metres(of: draft.sessions[0]) == 0)
        #expect(PlanPreview(draft: draft).days[1].text == "Strength · 3 min")
    }

    @Test func twoSessionsOnOneDayAreBothShown() throws {
        let draft = try decode(#"""
        {"date":"2026-11-03","type":"easy","steps":[{"kind":"work","goal":{"type":"distance","value":3000}}]},
        {"date":"2026-11-03","type":"strength","steps":[{"kind":"exercise","exerciseId":"plank","sets":4,"durationSec":300}]}
        """#)
        #expect(PlanPreview(draft: draft).days[1].text == "Easy run · 3 km + Strength · 20 min")
    }

    @Test func aSessionBeforeTheStartDateBelongsToNoWeek() throws {
        let draft = try decode(#"{"date":"2026-11-01","type":"easy","steps":[{"kind":"work","goal":{"type":"distance","value":9000}}]}"#)
        #expect(PlanPreview(draft: draft).bars.map(\.kilometres) == [0])
    }

    @Test func theSampleDurationUsesTheWorkStepsNotTheWarmUp() throws {
        let draft = try decode(#"""
        {"date":"2026-11-03","type":"tempo","title":"Tempo run","steps":[{"kind":"warmup","goal":{"type":"distance","value":1000}},
         {"kind":"work","goal":{"type":"distance","value":3000},"target":{"type":"pace","range":{"minSecPerKm":300,"maxSecPerKm":300}}},
         {"kind":"cooldown","goal":{"type":"distance","value":1000}}]}
        """#)
        #expect(PlanPreview(draft: draft).sample?.detail == "Moderate effort · 5:00–5:00/km · about 15 min")
    }

    @Test func aPlanWithNoSessionsStillBuilds() throws {
        let json = #"{"goal":{"type":"none"},"startDate":"2026-11-02","weekCount":1,"source":"rules","engine":{"presetId":"x","version":"1"},"adaptive":true,"weeks":[],"sessions":[],"assumptions":[],"warnings":[]}"#
        let p = PlanPreview(draft: try JSONDecoder().decode(Components.Schemas.PlanDraft.self, from: Data(json.utf8)))
        #expect(p.days.allSatisfy { $0.isRest })
        #expect(p.sample == nil)
    }
}
