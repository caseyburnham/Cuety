import SwiftUI

/// A state that changes what QLab does on a GO — broken, disarmed, loaded,
/// flagged, or continuing — with how every surface shows it. The detail
/// pills, the drawer's glyphs and their VoiceOver text all read from here.
struct CueState: Identifiable {
    let kind: DetailPillKind
    let title: String
    let systemImage: String
    let rotation: Angle
    let tint: Color
    let help: String
    /// How VoiceOver reads the state within a row's description.
    let spokenDescription: String

    var id: DetailPillKind { kind }

    /// The states in the order the drawer shows them.
    static let kinds: [DetailPillKind] = [.broken, .armed, .loaded, .flagged, .continueMode]

    static func states(of cue: Cue) -> [CueState] {
        kinds.compactMap { state($0, of: cue) }
    }

    /// The state `kind` describes, or nil when the cue is not in it.
    static func state(_ kind: DetailPillKind, of cue: Cue) -> CueState? {
        switch kind {
        case .broken where cue.isBroken == true:
            CueState(
                kind: kind, title: "Broken", systemImage: kind.systemImage, rotation: .zero,
                tint: .red, help: "Broken — QLab cannot fire this cue",
                spokenDescription: "broken"
            )
        case .armed where cue.isArmed == false:
            CueState(
                kind: kind, title: "Disarmed", systemImage: kind.systemImage,
                rotation: kind.glyphRotation, tint: .red,
                help: "Disarmed — QLab will skip this cue",
                spokenDescription: "disarmed, will be skipped"
            )
        case .loaded where cue.isLoaded == true:
            CueState(
                kind: kind, title: "Loaded", systemImage: kind.systemImage, rotation: .zero,
                tint: .yellow, help: "Loaded to a standby point",
                spokenDescription: "loaded"
            )
        case .flagged where cue.isFlagged == true:
            CueState(
                kind: kind, title: "Flagged", systemImage: kind.systemImage, rotation: .zero,
                tint: .yellow, help: "Flagged",
                spokenDescription: "flagged"
            )
        case .continueMode:
            cue.continueMode.flatMap { mode in
                mode == .doNotContinue ? nil : CueState(
                    kind: kind, title: mode.title, systemImage: mode.systemImage,
                    rotation: .zero, tint: .blue,
                    help: "\(mode.title) — this cue continues automatically",
                    spokenDescription: mode.title
                )
            }
        default:
            nil
        }
    }
}
