import APIClient
import Foundation

/// A suggested plan shaped like the DK-Preview board: 10 weeks of 16, 18, 21, 25, 20, 28, 31, 33, 24 and 16 km.
enum DraftFixture {
    static let weeklyKm: [Double] = [16, 18, 21, 25, 20, 28, 31, 33, 24, 16]
    static let phases = ["base", "base", "base", "build", "build", "build", "peak", "peak", "taper", "taper"]

    private static func date(startingMonday offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let day = calendar.date(byAdding: .day, value: offset, to: monday)!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func session(week: Int, day: Int, type: String, title: String, metres: Int, pace: (Int, Int)?) -> String {
        let target = pace.map { #","target":{"type":"pace","range":{"minSecPerKm":\#($0.0),"maxSecPerKm":\#($0.1)}}"# } ?? #","target":{"type":"effort","effort":"easy"}"#
        return #"{"date":"\#(date(startingMonday: week * 7 + day))","type":"\#(type)","title":"\#(title)","key":\#(type == "long"),"status":"planned","owner":"system","steps":[{"kind":"work","goal":{"type":"distance","value":\#(metres)}\#(target)}]}"#
    }

    /// Week 1 is Mon 4 km, Tue strength (20 min), Wed 4 km, Fri 3 km, Sat 5 km; later weeks split their distance the same way.
    static func json(
        weeklyKm: [Double] = DraftFixture.weeklyKm,
        phases: [String] = DraftFixture.phases,
        pace: (Int, Int)? = (385, 430),
        warnings: String = "[]"
    ) -> Data {
        var sessions: [String] = []
        for (week, km) in weeklyKm.enumerated() {
            let metres = Int(km * 1000)
            let long = week == 0 ? 5000 : metres * 3 / 10 / 100 * 100
            let friday = week == 0 ? 3000 : metres * 2 / 10 / 100 * 100
            let rest = metres - long - friday
            let monday = rest / 2 / 100 * 100
            sessions += [
                #"{"date":"\#(date(startingMonday: week * 7 + 1))","type":"strength","title":"Strength","status":"planned","owner":"system","steps":[{"kind":"exercise","exerciseId":"goblet-squat","sets":4,"durationSec":300}]}"#,
                session(week: week, day: 0, type: "easy", title: "Easy run", metres: monday, pace: pace),
                session(week: week, day: 2, type: "easy", title: "Easy run", metres: rest - monday, pace: pace),
                session(week: week, day: 4, type: "easy", title: "Easy run", metres: friday, pace: pace),
                session(week: week, day: 5, type: "long", title: "Long run", metres: long, pace: pace),
            ]
        }
        let weeks = phases.enumerated().map { #"{"index":\#($0.offset),"phase":"\#($0.element)"}"# }.joined(separator: ",")
        return Data(#"""
        {"goal":{"type":"10k","date":"2027-01-10"},"startDate":"2026-11-02","weekCount":\#(weeklyKm.count),"source":"rules",
         "engine":{"presetId":"10k","version":"0.1.0"},"adaptive":true,"weeks":[\#(weeks)],"sessions":[\#(sessions.joined(separator: ","))],
         "assumptions":[{"code":"paces_derived","message":"Easy pace of 6:25–7:10/km, estimated from your recent 5K of 28:30. Paces are ranges and start on the slower side."},
         {"code":"baseline","message":"Starting volume sits below your usual 20 km a week, so the first weeks feel comfortable."}],"warnings":\#(warnings)}
        """#.utf8)
    }

    static func draft(
        weeklyKm: [Double] = DraftFixture.weeklyKm,
        phases: [String] = DraftFixture.phases,
        pace: (Int, Int)? = (385, 430),
        warnings: String = "[]"
    ) throws -> Components.Schemas.PlanDraft {
        try JSONDecoder().decode(Components.Schemas.PlanDraft.self, from: json(weeklyKm: weeklyKm, phases: phases, pace: pace, warnings: warnings))
    }
}
