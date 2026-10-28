import Testing
@testable import RunningPlan

struct AppTabTests {
    @Test func tabsMatchTheDesignOrder() {
        #expect(AppTab.allCases == [.next, .plan, .progress, .goal])
        #expect(AppTab.allCases.map(\.title) == ["Next", "Plan", "Progress", "Goal"])
    }

    @Test func everyTabHasAnIconAndAScreenIdentifier() {
        for tab in AppTab.allCases {
            #expect(!tab.systemImage.isEmpty)
            #expect(tab.screenIdentifier == "screen.\(tab.rawValue)")
        }
    }

    @Test func appStartsOnNext() {
        #expect(AppTab.initial == .next)
    }
}
