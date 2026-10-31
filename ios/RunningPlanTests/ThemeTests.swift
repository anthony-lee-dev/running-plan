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
        #expect(Palette.greenInk == RGB(hex: "#0F2A20"))
        #expect(Palette.restRing == RGB(hex: "#7C7667"))
        #expect(Palette.chipText == RGB(hex: "#FFB59B"))
        #expect(Palette.greenSoft == RGB(hex: "#1D3A2E"))
        #expect(Palette.greenSoftText == RGB(hex: "#8EE0BF"))
        #expect(Palette.blueSoft == RGB(hex: "#1F2A4D"))
        #expect(Palette.blueText == RGB(hex: "#B7C7F5"))
        #expect(Palette.yoursText == RGB(hex: "#D8D2C2"))
        #expect(Palette.restBorder == RGB(hex: "#5C5748"))
        #expect(Palette.segmentTrack == RGB(hex: "#2D2A22"))
        #expect(Palette.segmentSelected == RGB(hex: "#443F33"))
    }

    @Test func minimumTouchTargetIs44() {
        #expect(Metrics.minTouchTarget == 44)
    }
}
