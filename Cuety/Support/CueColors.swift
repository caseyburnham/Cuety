import SwiftUI

/// The twenty named cue colors offered by QLab 5.2 and later.
nonisolated enum QLabCueColor: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case magenta
    case crimson
    case peach
    case olive
    case forest
    case skyBlue = "sky blue"
    case midnight
    case indigo
    case lavender
    case plum
    case berry
    case hotPink = "hot pink"
    case gray

    var id: String { rawValue }

    var title: String {
        rawValue.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    nonisolated var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .magenta: .cueMagenta
        case .crimson: .cueCrimson
        case .peach: .cuePeach
        case .olive: .cueOlive
        case .forest: .cueForest
        case .skyBlue: .cueSkyBlue
        case .midnight: .cueMidnight
        case .indigo: .indigo
        case .lavender: .cueLavender
        case .plum: .cuePlum
        case .berry: .cueBerry
        case .hotPink: .pink
        case .gray: .gray
        }
    }
}

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

    /// Builds a color from a packed 24-bit RGB value.
    private init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
