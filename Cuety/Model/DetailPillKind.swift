import SwiftUI

/// A piece of cue metadata that can be surfaced as a pill beneath the cue name.
///
/// Each kind knows its glyph, its label, and — importantly — the QLab cue key
/// it needs. Only the keys for *enabled* pills are requested, which is what
/// keeps `valuesForKeys` replies small.
enum DetailPillKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cueType
    case duration
    case preWait
    case postWait
    case continueMode
    case cueList
    case armed
    case flagged
    case notes

    var id: String { rawValue }

    /// The order pills appear in before the user rearranges them.
    static let defaultOrder: [DetailPillKind] = [
        .cueType, .duration, .preWait, .postWait, .continueMode, .cueList, .armed, .flagged, .notes,
    ]

    /// The pills switched on for a fresh install: what an operator reads at a
    /// glance, without the long-tail extras cluttering the row.
    static let defaultEnabled: Set<DetailPillKind> = [
        .cueType, .duration, .preWait, .continueMode,
    ]

    var title: String {
        switch self {
        case .cueType: "Type"
        case .duration: "Duration"
        case .preWait: "Pre-wait"
        case .postWait: "Post-wait"
        case .continueMode: "Continue"
        case .cueList: "Cue List"
        case .armed: "Armed"
        case .flagged: "Flagged"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .cueType: "square.stack.3d.up"
        case .duration: "clock"
        case .preWait: "hourglass.tophalf.filled"
        case .postWait: "hourglass.bottomhalf.filled"
        case .continueMode: "arrow.turn.down.right"
        case .cueList: "list.bullet"
        case .armed: "power"
        case .flagged: "flag"
        case .notes: "text.alignleft"
        }
    }

    /// The QLab cue property key backing this pill, or `nil` when the value is
    /// already present in the cue-list reply and needs no extra query.
    var qlabKey: String? {
        switch self {
        case .cueType: nil          // present in /cueLists
        case .cueList: nil          // present in /cueLists as listName
        case .armed: nil            // present in /cueLists
        case .flagged: nil          // present in /cueLists
        case .duration: "duration"
        case .preWait: "preWait"
        case .postWait: "postWait"
        case .continueMode: "continueMode"
        case .notes: "notes"
        }
    }

    /// A short explanation shown beside the toggle in Settings.
    var settingsDescription: String {
        switch self {
        case .cueType: "The kind of cue — audio, video, light, group, and so on."
        case .duration: "How long the cue runs, when it has a duration."
        case .preWait: "Delay before the cue acts, when non-zero."
        case .postWait: "Delay before the following cue, when non-zero."
        case .continueMode: "Whether the cue auto-continues or auto-follows."
        case .cueList: "The name of the cue list the cue belongs to."
        case .armed: "Shown only when the cue is disarmed."
        case .flagged: "Shown only when the cue is flagged."
        case .notes: "The cue's notes field, when it has any."
        }
    }
}
