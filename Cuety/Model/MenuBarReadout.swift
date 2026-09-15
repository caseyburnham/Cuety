import SwiftUI

/// What Cuety's menu bar item shows while its menu is closed.
///
/// Three readouts rather than one, because the menu bar item is answering a
/// different question depending on what the operator is doing. Mid-show, the
/// cue standing by is the only thing worth the space. Setting up, whether
/// Cuety is talking to QLab at all is the whole question — and a heartbeat
/// answers that more precisely than a status glyph can, because it reports the
/// link rather than Cuety's opinion of the link.
enum MenuBarReadout: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// The number of the cue standing by at the playhead.
    case cueNumber
    /// The connection status glyph — the same one the header bar shows.
    case connectionStatus
    /// A heart that beats once per `/thump` QLab answers.
    case heartbeat

    var id: String { rawValue }

    /// The readout Cuety shows until the operator says otherwise. The cue
    /// number, because that is what the app is for.
    static let `default` = MenuBarReadout.cueNumber

    var title: String {
        switch self {
        case .cueNumber: "Cue Number"
        case .connectionStatus: "Connection Status"
        case .heartbeat: "Heartbeat"
        }
    }

    /// What the operator will actually see, for the Settings picker's help.
    var detail: String {
        switch self {
        case .cueNumber:
            "The number of the cue standing by, falling back to the connection status when there is no cue to show."
        case .connectionStatus:
            "A glyph for the state of the QLab session."
        case .heartbeat:
            "A heart that beats once for every heartbeat QLab answers."
        }
    }
}
