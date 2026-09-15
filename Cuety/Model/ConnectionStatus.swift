import SwiftUI

enum ConnectionStatus: Hashable, Sendable {
    case offline
    case connecting
    case reconnecting(attempt: Int, reason: String)
    case needsPasscode(rejected: Bool)
    case connected
    case degraded(reason: String)
    case workspaceClosed
    case failed(reason: String)

    var systemImage: String {
        switch self {
        case .offline: "circle.slash"
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

    var isTransitional: Bool {
        if case .connecting = self { return true }
        return false
    }

    var hasLiveData: Bool {
        switch self {
        case .connected, .degraded: true
        case .offline, .connecting, .reconnecting, .needsPasscode, .workspaceClosed, .failed:
            false
        }
    }
}
