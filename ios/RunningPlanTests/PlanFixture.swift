import APIClient
import Foundation
@testable import RunningPlan

/// A saved plan shaped like the DK-Next, DK-Week and DK-Whole boards: a 10-week 10K starting Mon 2026-10-05 (race
/// Sun 2026-12-13), weeks of 16, 18, 21, 25, 20, 28, 31, 33, 24 and 16 km. Week 4 (Oct 26 to Nov 1) is the boards'
/// week: Mon easy 5 km (done), Tue strength (done), Wed intervals 5 × 600 m (6.9 km), Thu rest, Fri easy 5 km,
/// Sat long 8 km, Sun 45 min cycling (the user's own). Weeks 1 to 3 are done. The boards' today is Wed 2026-10-28.
enum PlanFixture {
    static let today = "2026-10-28"
    static let planID = "7d0c3b5e-0f6a-4c1e-9b2d-6a1f0e9c8b70"
    static let weeklyKm: [Double] = [16, 18, 21, 25, 20, 28, 31, 33, 24, 16]
    static let phases = ["base", "base", "base", "build", "build", "build", "peak", "peak", "taper", "taper"]

    static func date(_ offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let day = calendar.date(byAdding: .day, value: offset, to: start)!
        let p = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }

    private static let easyPace = #"{"type":"pace","range":{"minSecPerKm":385,"maxSecPerKm":430}}"#

    private static func run(_ offset: Int, _ type: String, _ title: String, metres: Int, key: Bool = false, done: Bool) -> String {
        #"{"date":"\#(date(offset))","type":"\#(type)","title":"\#(title)","key":\#(key),"status":"\#(done ? "done" : "planned")","owner":"system","steps":[{"kind":"work","goal":{"type":"distance","value":\#(metres)},"target":\#(easyPace)}]}"#
    }

    private static func strength(_ offset: Int, done: Bool) -> String {
        #"{"date":"\#(date(offset))","type":"strength","title":"Strength","status":"\#(done ? "done" : "planned")","owner":"system","steps":[{"kind":"exercise","exerciseId":"goblet-squat","sets":4,"durationSec":300}]}"#
    }

    private static let intervals = #"{"date":"\#(date(23))","type":"intervals","title":"Intervals: 5 × 600 m","key":true,"status":"planned","owner":"system","steps":[{"kind":"warmup","goal":{"type":"distance","value":1500},"target":\#(easyPace)},{"kind":"repeat","count":5,"steps":[{"kind":"work","goal":{"type":"distance","value":600},"target":{"type":"pace","range":{"minSecPerKm":315,"maxSecPerKm":330}}},{"kind":"recovery","goal":{"type":"distance","value":200},"target":{"type":"effort","effort":"easy"}}]},{"kind":"cooldown","goal":{"type":"distance","value":1400},"target":\#(easyPace)}]}"#

    private static let cycling = #"{"date":"\#(date(27))","type":"custom","title":"Cycling","status":"planned","owner":"user","custom":{"activityLabel":"cycling","goal":{"type":"time","value":2700},"effort":"easy"}}"#

    /// The sessions without sync metadata, in date order.
    static func sessionContents() -> [String] {
        var sessions: [String] = []
        for (week, km) in weeklyKm.enumerated() {
            let base = week * 7
            if week == 3 {
                sessions += [
                    run(base, "easy", "Easy run", metres: 5000, done: true),
                    strength(base + 1, done: true),
                    intervals,
                    run(base + 4, "easy", "Easy run", metres: 5000, done: false),
                    run(base + 5, "long", "Long run", metres: 8000, key: true, done: false),
                    cycling,
                ]
                continue
            }
            let metres = Int(km * 1000)
            let done = week < 3
            let long = metres * 3 / 10 / 100 * 100
            let friday = metres * 2 / 10 / 100 * 100
            let monday = (metres - long - friday) / 2 / 100 * 100
            sessions += [
                run(base, "easy", "Easy run", metres: monday, done: done),
                strength(base + 1, done: done),
                run(base + 2, "easy", "Easy run", metres: metres - long - friday - monday, done: done),
                run(base + 4, "easy", "Easy run", metres: friday, done: done),
                run(base + 5, "long", "Long run", metres: long, key: true, done: done),
            ]
        }
        return sessions
    }

    /// `extra` adds sessions (content JSON) to the board's plan, for cases the boards do not show.
    static func json(id: String = planID, extra: [String] = [], replacing: [String]? = nil) -> Data {
        let sessions = ((replacing ?? sessionContents()) + extra).enumerated().map { index, content in
            let meta = #""id":"\#(String(format: "00000000-0000-4000-8000-%012d", index))","planId":"\#(id)","revision":1,"updatedAt":"2026-10-28T07:42:00.000Z","deletedAt":null,"#
            return "{" + meta + content.dropFirst()
        }
        let weeks = phases.enumerated().map { #"{"index":\#($0.offset),"phase":"\#($0.element)"}"# }.joined(separator: ",")
        return Data(#"""
        {"id":"\#(id)","revision":3,"updatedAt":"2026-10-28T07:42:00.000Z","deletedAt":null,"contentRevision":3,
         "goal":{"type":"10k","date":"2026-12-13","targetTimeSec":3300},"startDate":"2026-10-05","weekCount":10,"source":"rules",
         "engine":{"presetId":"10k","version":"0.1.0"},"adaptive":true,"weeks":[\#(weeks)],"sessions":[\#(sessions.joined(separator: ","))],"warnings":[]}
        """#.utf8)
    }

    /// `replacing` swaps the board's sessions for others (content JSON); `extra` adds to them.
    static func detail(id: String = planID, extra: [String] = [], replacing: [String]? = nil) throws -> Components.Schemas.PlanDetail {
        try APIConfiguration.decoder.decode(Components.Schemas.PlanDetail.self, from: json(id: id, extra: extra, replacing: replacing))
    }

    /// A rest session on Thursday of week 4, which the user may add by hand.
    static let restThursday = #"{"date":"2026-10-29","type":"rest","title":"Rest day","status":"planned","owner":"user"}"#
}
