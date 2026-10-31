import SwiftUI

/// An sRGB colour from the design tokens, kept as plain numbers so it can be tested.
struct RGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB`; nil for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// Dark-theme tokens from docs/design-notes.md.
enum Palette {
    static let bg = RGB(red: 0x1C, green: 0x1A, blue: 0x15)
    static let card = RGB(red: 0x27, green: 0x24, blue: 0x1D)
    static let ink = RGB(red: 0xF5, green: 0xF1, blue: 0xE6)
    static let muted = RGB(red: 0xAB, green: 0xA5, blue: 0x97)
    static let line = RGB(red: 0x3A, green: 0x36, blue: 0x2B)
    static let accent = RGB(red: 0xC9, green: 0x41, blue: 0x1B)
    /// Border of a selected option and the progress fill, a raw value the boards use without a token name.
    static let accentBorder = RGB(red: 0xF0, green: 0x64, blue: 0x3A)
    static let accentText = RGB(red: 0xFF, green: 0x8A, blue: 0x63)
    static let accentSoft = RGB(red: 0x4A, green: 0x24, blue: 0x18)
    static let green = RGB(red: 0x4F, green: 0xC7, blue: 0x9A)
    static let tabBar = RGB(red: 0x14, green: 0x13, blue: 0x10)
    /// The tick on a done day (on `green`), a rest day's dashed ring, and text on an `accentSoft` chip (DK-Next).
    static let greenInk = RGB(red: 0x0F, green: 0x2A, blue: 0x20)
    static let restRing = RGB(red: 0x7C, green: 0x76, blue: 0x67)
    static let chipText = RGB(red: 0xFF, green: 0xB5, blue: 0x9B)
    /// Badges by meaning (DK-Week): easy, long run, and the user's own sessions.
    static let greenSoft = RGB(red: 0x1D, green: 0x3A, blue: 0x2E)
    static let greenSoftText = RGB(red: 0x8E, green: 0xE0, blue: 0xBF)
    static let blueSoft = RGB(red: 0x1F, green: 0x2A, blue: 0x4D)
    static let blueText = RGB(red: 0xB7, green: 0xC7, blue: 0xF5)
    static let yoursText = RGB(red: 0xD8, green: 0xD2, blue: 0xC2)
    /// The Week / Whole plan switch: its track and the selected segment.
    static let segmentTrack = RGB(red: 0x2D, green: 0x2A, blue: 0x22)
    static let segmentSelected = RGB(red: 0x44, green: 0x3F, blue: 0x33)
    /// The goal card on DK-Whole: fill, border, text and progress track.
    static let goalCard = RGB(red: 0x33, green: 0x29, blue: 0x1F)
    static let goalBorder = RGB(red: 0x4A, green: 0x3C, blue: 0x2B)
    static let goalText = RGB(red: 0xCF, green: 0xC8, blue: 0xB8)
    static let goalTrack = RGB(red: 0x4A, green: 0x46, blue: 0x38)
    /// The dashed border of a rest day's card (DK-Week).
    static let restBorder = RGB(red: 0x5C, green: 0x57, blue: 0x48)
    /// Notice cards ("What we assumed", warnings): fill and the three text colours the boards use on it.
    static let amberSoft = RGB(red: 0x3B, green: 0x31, blue: 0x15)
    static let amberTitle = RGB(red: 0xF7, green: 0xE3, blue: 0xA6)
    static let amberText = RGB(red: 0xE5, green: 0xD2, blue: 0x9B)
    static let amberLink = RGB(red: 0xFF, green: 0xC3, blue: 0x8A)
    /// Bar chart colours by plan phase.
    static let phaseBase = RGB(red: 0x4C, green: 0x9C, blue: 0x80)
    static let phaseBuild = RGB(red: 0xE9, green: 0xB9, blue: 0x49)
    static let phasePeak = RGB(red: 0xF0, green: 0x64, blue: 0x3A)
    static let phaseTaper = RGB(red: 0x8C, green: 0x9F, blue: 0xD8)
}

enum Metrics {
    static let minTouchTarget: CGFloat = 44
}
