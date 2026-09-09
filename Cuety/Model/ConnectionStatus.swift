import SwiftUI

/// Where the connection to QLab currently stands.
///
/// Strictly the state of the *session*: network discovery is the browser's
/// business, not this type's. The cases are ordered from least to most
/// connected, and each one carries its own glyph, tint, and human-readable
/// phrasing. Keeping presentation on the state itself means the toolbar glyph,
/// the inspector, and the cue display cannot disagree about what "degraded"
/// looks like.
enum ConnectionStatus: Hashable, Sendable {
    /// No connection attempted.
    case offline
    /// TCP connecting, or mid-handshake.
    case connecting
    /// The session dropped and Cuety is waiting out its backoff before trying
    /// again. `reason` is why the last attempt ended.
    ///
    /// Distinct from ``failed`` on purpose: both mean there is nothing on
    /// screen to trust, but only one of them is going to fix itself. An
    /// operator watching a dead display needs to know whether Cuety is still
    /// working on it.
    case reconnecting(attempt: Int, reason: String)
    /// The workspace requires a passcode we don't have or that was rejected.
    case needsPasscode(rejected: Bool)
    /// Connected, subscribed, and receiving heartbeats.
    case connected
    /// Connected, but heartbeats are being missed or the path is unsatisfied.
    case degraded(reason: String)
    /// The workspace we were watching is no longer open in QLab.
    ///
    /// A terminal state rather than a failure: QLab is answering perfectly
    /// well, it just doesn't have this workspace any more, so retrying would
    /// only ask the same question again.
    case workspaceClosed
    /// The connection failed; `reason` is shown in the inspector.
    case failed(reason: String)

    var systemImage: String {
        switch self {
        case .offline: "bolt.horizontal.circle"
        case .connecting: "progress.indicator"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .needsPasscode: "lock.circle"
        case .connected: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .workspaceClosed: "rectangle.badge.xmark"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .offline: .secondary
        case .connecting: .accentColor
        case .reconnecting: .orange
        case .needsPasscode: .orange
        case .connected: .green
        case .degraded: .yellow
        case .workspaceClosed: .orange
        case .failed: .red
        }
    }

    /// A terse label for the header glyph's tooltip and accessibility label.
    var title: String {
        switch self {
        case .offline: "Not Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .needsPasscode(let rejected): rejected ? "Passcode Rejected" : "Passcode Required"
        case .connected: "Connected"
        case .degraded: "Connection Degraded"
        case .workspaceClosed: "Workspace Closed"
        case .failed: "Connection Failed"
        }
    }

    /// A fuller sentence for the inspector and empty states.
    var detail: String {
        switch self {
        case .offline:
            "Choose a QLab workspace in the sidebar to connect."
        case .connecting:
            "Opening a connection to QLab."
        case .reconnecting(let attempt, let reason):
            "\(reason) Trying again — attempt \(attempt)."
        case .needsPasscode(let rejected):
            rejected
                ? "That passcode was not accepted. Try again."
                : "This workspace is protected by a passcode."
        case .connected:
            "Receiving cue updates from QLab."
        case .degraded(let reason):
            reason
        case .workspaceClosed:
            "This workspace is no longer open in QLab. Choose another in the sidebar."
        case .failed(let reason):
            reason
        }
    }

    /// Whether the status glyph should animate to convey ongoing work.
    ///
    /// Call sites also use this to hold off starting a second attempt, which is
    /// why `reconnecting` is deliberately excluded: its backoff can run for
    /// half a minute, and disabling Connect and Refresh for that long would
    /// leave the operator unable to intervene in exactly the situation where
    /// they most want to.
    var isTransitional: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Whether cue data on screen can still be trusted.
    ///
    /// `degraded` deliberately counts as live: the last known playhead is still
    /// the best information available, and blanking the display because a
    /// heartbeat was missed would be worse than showing slightly stale data.
    var hasLiveData: Bool {
        switch self {
        case .connected, .degraded: true
        case .offline, .connecting, .reconnecting, .needsPasscode, .workspaceClosed, .failed:
            false
        }
    }
}
