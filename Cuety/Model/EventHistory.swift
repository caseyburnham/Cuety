import Foundation
import Observation
import ShowControlCore

@Observable
@MainActor
final class EventHistory {
    struct Event: Identifiable {
        enum Kind: String {
            case go = "GO"
            case start = "Start"
            case stop = "Stop"
            case panic = "Panic All"
            case connecting = "Connecting"
            case connected = "Connected"
            case disconnected = "Disconnected"
            case connectionLost = "Connection Lost"
            case reconnecting = "Reconnecting"
            case workspaceClosed = "Workspace Closed"
            case passcodeRequired = "Passcode Required"
            case passcodeRejected = "Passcode Rejected"
            case connectionFailed = "Connection Failed"
            case missedEvents = "Missed Events"

            var isCueEvent: Bool {
                switch self {
                case .go, .start, .stop, .panic: true
                default: false
                }
            }
        }

        let id = UUID()
        let timestamp: Date
        let kind: Kind
        let cueID: String?
        let cueNumber: String
        let cueName: String
        let observationID: UUID?
        let workspaceName: String?
        let detail: String?

        var cueLabel: String {
            [cueNumber, cueName].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private(set) var endedAt: Date?
    private(set) var isIncomplete = false
    private(set) var recentEvents: [Event] = []
    private(set) var observationID: UUID?

    func reset() {
        recentEvents.removeAll()
        observationID = nil
        endedAt = nil
        isIncomplete = false
    }

    func beginObservation(at _: Date = Date()) {
        observationID = UUID()
        endedAt = nil
        isIncomplete = false
    }

    func endObservation(at date: Date = Date()) {
        guard observationID != nil, endedAt == nil else { return }
        endedAt = date
    }

    func markIncomplete() {
        guard observationID != nil, endedAt == nil else { return }
        isIncomplete = true
    }

    func clearRecentEvents() {
        recentEvents.removeAll()
    }

    func record(_ message: OSCMessage, timestamp: Date = Date(), workspaceName: String? = nil) {
        guard observationID != nil, endedAt == nil else { return }

        let kind: Event.Kind
        switch message.address {
        case "/qlab/event/workspace/go": kind = .go
        case "/qlab/event/workspace/cue/start": kind = .start
        case "/qlab/event/workspace/cue/stop": kind = .stop
        case "/qlab/event/workspace/panicAll": kind = .panic
        default: return
        }

        // Base cue broadcasts carry four strings. Detail broadcasts and malformed
        // packets are not useful event-history entries.
        if kind == .panic {
            guard message.arguments.isEmpty else { return }
        } else {
            guard message.arguments.count == 4,
                  message.arguments.allSatisfy({ $0.stringValue != nil }) else { return }
        }

        let strings = message.arguments.map { $0.stringValue ?? "" }
        append(Event(
            timestamp: timestamp,
            kind: kind,
            cueID: kind == .panic || strings[2].isEmpty ? nil : strings[2],
            cueNumber: kind == .panic ? "" : strings[0],
            cueName: kind == .panic ? "" : strings[1],
            observationID: observationID,
            workspaceName: workspaceName,
            detail: nil
        ))
    }

    func recordLifecycle(
        _ kind: Event.Kind,
        workspaceName: String? = nil,
        detail: String? = nil,
        timestamp: Date = Date()
    ) {
        guard !kind.isCueEvent else { return }
        append(Event(
            timestamp: timestamp,
            kind: kind,
            cueID: nil,
            cueNumber: "",
            cueName: "",
            observationID: endedAt == nil ? observationID : nil,
            workspaceName: workspaceName,
            detail: detail
        ))
    }

    private func append(_ event: Event) {
        recentEvents.append(event)
        if recentEvents.count > 100 {
            recentEvents.removeFirst(recentEvents.count - 100)
        }
    }
}
