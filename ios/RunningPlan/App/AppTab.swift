/// The four main tabs, in the order of the DK boards' bottom navigation.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case next, plan, progress, goal

    static let initial: AppTab = .next

    var id: String { rawValue }

    var title: String {
        switch self {
        case .next: "Next"
        case .plan: "Plan"
        case .progress: "Progress"
        case .goal: "Goal"
        }
    }

    /// SF Symbols closest to the board icons (play, calendar, bars, flag).
    var systemImage: String {
        switch self {
        case .next: "play.circle"
        case .plan: "calendar"
        case .progress: "chart.bar"
        case .goal: "flag"
        }
    }

    /// Accessibility identifier of the tab's screen, for UI tests.
    var screenIdentifier: String { "screen.\(rawValue)" }
}
