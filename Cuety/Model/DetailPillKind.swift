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

    /// The glyph this pill uses.
    ///
    /// Also what Settings shows beside the pill's toggle, so the two cannot
    /// disagree about what a pill looks like. ``DetailPillKind/cueType`` is the
    /// one kind that overrides it, picking a symbol per QLab cue type.
    var systemImage: String {
        switch self {
        case .cueType: "square.stack.3d.up"
        case .duration: "clock"
        case .preWait: "hourglass.tophalf.filled"
        case .postWait: "hourglass.bottomhalf.filled"
        // Auto-continue's glyph, standing in for a pill that draws whichever
        // of the two modes the cue is actually in. It has to be one of them:
        // `arrow.turn.down.right` used to sit here, a symbol that appears on
        // no pill at all, so the Settings row previewed something the display
        // would never show.
        case .continueMode: "arrow.down"
        case .cueList: "list.bullet"
        case .armed: "power"
        case .flagged: "flag.fill"
        case .notes: "ellipsis.bubble"
        }
    }

    /// How far to turn this pill's glyph.
    ///
    /// Disarmed is an inverted power symbol, the way QLab draws a disarmed
    /// cue, rather than the upright one that means the opposite. Read by the
    /// pill, by the drawer's row indicator, and by the Settings list, so the
    /// three cannot end up drawing it different ways up.
    var glyphRotation: Angle {
        switch self {
        case .armed: .degrees(180)
        default: .zero
        }
    }

    /// The QLab cue property key backing this pill, or `nil` when the value is
    /// already present in the cue-list reply and needs no extra query.
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
        // Says where it lands as well as what it is: notes always take a line
        // of their own beneath the rest, so unlike every other pill here, this
        // one's position in the order doesn't change what you see.
        case .notes: "The cue's notes field, when it has any. Always on its own line, below the others."
        }
    }
}
