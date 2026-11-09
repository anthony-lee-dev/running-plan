import APIClient
import Foundation

/// Run details (issue #131): what the screen shows for one imported run. Pure. A stat the source did not record is left
/// out (never 0 or a dash) and one short note says the data is limited. No DK board exists; the layout follows the
/// design review on the issue: hero stats, secondary grid, plan vs actual, splits, zones.
struct RunDetailsModel: Equatable {
    struct Stat: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let source: String
    /// "Matched · Easy run · 5 km", or "Not part of a plan".
    let planChip: String
    let hero: [Stat]
    let grid: [Stat]
    let limitedDataNote: String?
    let planVsActual: CheckInModel?

    /// `splitsMissing`: Health was read and gave no per-kilometre data for this run.
    init(activity a: Components.Schemas.ActivityFields, session: Components.Schemas.SessionContent?, splitsMissing: Bool) {
        title = LocalDay.heading(a.localDate)
        source = a.sourceApp ?? "Apple Health"
        let isRun = a.workoutType == .running
        var hero: [Stat] = []
        let metres = a.distanceM ?? 0
        if metres > 0 { hero.append(Stat(label: "Distance", value: String(format: "%.2f km", Double(metres) / 1000))) }
        hero.append(Stat(label: "Time", value: InboxModel.duration(a.durationSec)))
        if isRun, metres > 0 {
            hero.append(Stat(label: "Pace", value: "\(PaceFormat.minutesSeconds(Int((Double(a.durationSec) / (Double(metres) / 1000)).rounded())))/km"))
        }
        self.hero = hero
        var grid: [Stat] = []
        if let hr = a.avgHeartRate { grid.append(Stat(label: "Avg heart rate", value: "\(hr) bpm")) }
        if let hr = a.maxHeartRate { grid.append(Stat(label: "Max heart rate", value: "\(hr) bpm")) }
        if let climb = a.elevationGainM { grid.append(Stat(label: "Elevation gain", value: "\(climb) m")) }
        if let cadence = a.avgCadence { grid.append(Stat(label: "Cadence", value: "\(cadence) spm")) }
        self.grid = grid
        let missing = a.avgHeartRate == nil || a.maxHeartRate == nil || a.elevationGainM == nil
        limitedDataNote = isRun && (missing || splitsMissing)
            ? "Limited data from \(source): the stats it didn't record are left out." : nil
        if let session {
            let name = session.title ?? SessionSummary.effort(session)
            let planned = PlanPreview.metres(of: session)
            planChip = "Matched · " + name + (planned > 0 ? " · \(PlanPreview.kilometres(planned / 1000)) km" : "")
            planVsActual = CheckInModel(session: session, activity: a)
        } else {
            planChip = "Not part of a plan"
            planVsActual = nil
        }
    }
}
