import SwiftUI

/// Colors for QLab cue color names that have no SwiftUI equivalent.
nonisolated extension Color {
    static let cueMagenta = Color(hex: 0xC9269B)
    static let cueCrimson = Color(hex: 0xA6182E)
    static let cuePeach = Color(hex: 0xFFAD8A)
    static let cueOlive = Color(hex: 0x7E8C2B)
    static let cueForest = Color(hex: 0x1E6B3A)
    static let cueSkyBlue = Color(hex: 0x61B8E8)
    static let cueMidnight = Color(hex: 0x1B2A5E)
    static let cueLavender = Color(hex: 0xB79CE0)
    static let cuePlum = Color(hex: 0x7A3B7E)
    static let cueBerry = Color(hex: 0x9B1C4B)

    /// Builds a color from a packed 24-bit RGB value, e.g. `0xFF8800`.
    private init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
