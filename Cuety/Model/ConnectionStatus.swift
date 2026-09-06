import SwiftUI

/// Where the connection to QLab currently stands.
///
/// The cases are ordered from least to most connected, and each one carries its
/// own glyph, tint, and human-readable phrasing. Keeping presentation on the
/// state itself means the header glyph, the inspector, and the sidebar cannot
/// disagree about what "degraded" looks like.
enum ConnectionStatus: Hashable, Sendable {
    /// No connection attempted.
    case offline
    /// Looking for QLab instances on the network.
    case browsing
    /// TCP connecting, or mid-handshake.
    case connecting
    /// The workspace requires a passcode we don't have or that was rejected.
    case needsPasscode(rejected: Bool)
    /// Connected, subscribed, and receiving heartbeats.
    case connected
    /// Connected, but heartbeats are being missed or the path is unsatisfied.
    case degraded(reason: String)
    /// The connection failed; `reason` is shown in the inspector.
    case failed(reason: String)

    var systemImage: String {
        switch self {
        case .offline: "bolt.horizontal.circle"
        case .browsing: "antenna.radiowaves.left.and.right"
        case .connecting: "progress.indicator"
        case .needsPasscode: "lock.circle"
        case .connected: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .offline: .secondary
        case .browsing, .connecting: .accentColor
        case .needsPasscode: .orange
        case .connected: .green
        case .degraded: .yellow
        case .failed: .red
        }
    }

    /// A terse label for the header glyph's tooltip and accessibility label.
    var title: String {
        switch self {
        case .offline: "Not Connected"
        case .browsing: "Searching"
        case .connecting: "Connecting"
        case .needsPasscode(let rejected): rejected ? "Passcode Rejected" : "Passcode Required"
        case .connected: "Connected"
        case .degraded: "Connection Degraded"
        case .failed: "Connection Failed"
        }
    }

    /// A fuller sentence for the inspector and empty states.
    var detail: String {
        switch self {
        case .offline:
            "Choose a QLab workspace to connect."
        case .browsing:
            "Looking for QLab on the local network."
        case .connecting:
            "Opening a connection to QLab."
        case .needsPasscode(let rejected):
            rejected
                ? "That passcode was not accepted. QLab delays repeated attempts, so wait a moment before trying again."
                : "This workspace is protected by a passcode."
        case .connected:
            "Receiving cue updates from QLab."
        case .degraded(let reason):
            reason
        case .failed(let reason):
            reason
        }
    }

    /// Whether the status glyph should animate to convey ongoing work.
    var isTransitional: Bool {
        switch self {
        case .browsing, .connecting: true
        default: false
        }
    }

    /// Whether cue data on screen can still be trusted.
    ///
    /// `degraded` deliberately counts as live: the last known playhead is still
    /// the best information available, and blanking the display because a
    /// heartbeat was missed would be worse than showing slightly stale data.
    var hasLiveData: Bool {
        switch self {
        case .connected, .degraded: true
        case .offline, .browsing, .connecting, .needsPasscode, .failed: false
        }
    }
}
