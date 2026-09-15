import SwiftUI

enum MenuBarReadout: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cueNumber
    case connectionStatus
    case heartbeat

    var id: String { rawValue }

    static let `default` = MenuBarReadout.cueNumber

    var title: String {
        switch self {
        case .cueNumber: "Cue Number"
        case .connectionStatus: "Connection Status"
        case .heartbeat: "Heartbeat"
        }
    }

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
