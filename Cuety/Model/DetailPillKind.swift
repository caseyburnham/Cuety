import SwiftUI

enum DetailPillKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case broken
    case cueType
    case duration
    case preWait
    case postWait
    case continueMode
    case cueList
    case armed
    case loaded
    case flagged
    case notes

    var id: String { rawValue }

    static let defaultOrder: [DetailPillKind] = [
        .broken, .flagged, .loaded, .cueType, .preWait, .duration, .postWait,
        .continueMode, .cueList, .armed, .notes,
    ]

    static let defaultEnabled: Set<DetailPillKind> = [
        .broken, .cueType, .duration, .preWait, .continueMode, .armed, .loaded, .flagged,
    ]

    /// A cue QLab cannot fire is not something an operator should have to
    /// opt into being told about, so this pill ignores the enabled set.
    static let alwaysVisible: Set<DetailPillKind> = [.broken]

    var isAlwaysVisible: Bool { Self.alwaysVisible.contains(self) }

    var title: String {
        switch self {
        case .broken: "Broken"
        case .cueType: "Type"
        case .duration: "Duration"
        case .preWait: "Pre-wait"
        case .postWait: "Post-wait"
        case .continueMode: "Continue"
        case .cueList: "Cue List"
        case .armed: "Armed"
        case .loaded: "Loaded"
        case .flagged: "Flagged"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .broken: "xmark"
        case .cueType: "square.stack.3d.up"
        case .duration: "clock"
        case .preWait: "hourglass.tophalf.filled"
        case .postWait: "hourglass.bottomhalf.filled"
        case .continueMode: "arrow.down"
        case .cueList: "list.bullet"
        case .armed: "power"
        case .loaded: "arrow.down.to.line.circle"
        case .flagged: "flag.fill"
        case .notes: "ellipsis.bubble"
        }
    }

    var glyphRotation: Angle {
        switch self {
        case .armed: .degrees(180)
        default: .zero
        }
    }

    var qlabKey: String? {
        switch self {
        case .cueType: nil          // present in /cueLists
        case .cueList: nil          // derived from the /cueLists tree
        case .armed: nil            // present in /cueLists
        case .flagged: nil          // present in /cueLists
        case .duration: "duration"
        case .preWait: "preWait"
        case .postWait: "postWait"
        case .continueMode: "continueMode"
        case .notes: "notes"
        case .broken: "isBroken"
        case .loaded: "isLoaded"
        }
    }

    var settingsDescription: String {
        switch self {
        case .broken: "Always shown. QLab cannot fire this cue — a missing file, patch, or target."
        case .cueType: "The kind of cue — audio, video, light, group, and so on."
        case .duration: "How long the cue runs, when it has a duration."
        case .preWait: "Delay before the cue acts, when non-zero."
        case .postWait: "Delay before the following cue, when non-zero."
        case .continueMode: "Whether the cue auto-continues or auto-follows."
        case .cueList: "The name of the cue list the cue belongs to."
        case .armed: "Shown only when the cue is disarmed, and will be skipped."
        case .loaded: "Shown only when QLab has loaded the cue to a standby point."
        case .flagged: "Shown only when the cue is flagged."
        case .notes: "The cue's notes field, when it has any. Always on its own line, below the others."
        }
    }
}
