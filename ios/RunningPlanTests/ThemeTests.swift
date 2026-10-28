import Testing
@testable import RunningPlan

struct ThemeTests {
    @Test(arguments: [
        ("#1C1A15", RGB(red: 0x1C, green: 0x1A, blue: 0x15)),
        ("C9411B", RGB(red: 0xC9, green: 0x41, blue: 0x1B)),
        ("#ffffff", RGB(red: 255, green: 255, blue: 255)),
    ])
    func parsesHex(hex: String, expected: RGB) {
        #expect(RGB(hex: hex) == expected)
    }

    @Test(arguments: ["", "#12345", "#GGGGGG", "#1234567"])
    func rejectsBadHex(hex: String) {
        #expect(RGB(hex: hex) == nil)
    }

    @Test func tokensMatchDesignNotes() {
        #expect(Palette.bg == RGB(hex: "#1C1A15"))
        #expect(Palette.card == RGB(hex: "#27241D"))
        #expect(Palette.ink == RGB(hex: "#F5F1E6"))
        #expect(Palette.muted == RGB(hex: "#ABA597"))
        #expect(Palette.accent == RGB(hex: "#C9411B"))
        #expect(Palette.accentText == RGB(hex: "#FF8A63"))
        #expect(Palette.line == RGB(hex: "#3A362B"))
        #expect(Palette.accentSoft == RGB(hex: "#4A2418"))
        #expect(Palette.green == RGB(hex: "#4FC79A"))
        #expect(Palette.tabBar == RGB(hex: "#141310"))
    }

    @Test func minimumTouchTargetIs44() {
        #expect(Metrics.minTouchTarget == 44)
    }
}
