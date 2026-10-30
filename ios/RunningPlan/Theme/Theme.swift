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
