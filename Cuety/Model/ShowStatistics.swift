import Foundation
import Observation
import ShowControlCore

@Observable
@MainActor
final class ShowStatistics {
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

    struct Repeat: Identifiable {
        let id: String
        let label: String
        let count: Int
    }

    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var lastGO: Date?
    private(set) var lastPanic: Date?
    private(set) var goCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var panicCount = 0
    private(set) var gosSinceLastPanic = 0
    private(set) var isIncomplete = false
    private(set) var recentEvents: [Event] = []
    private(set) var observedCueIDs: Set<String> = []
    private(set) var observationID: UUID?

    var uniqueCueCount: Int { observedCueIDs.count }

    var currentObservationEvents: [Event] {
        guard let observationID else { return [] }
        return recentEvents.filter { $0.observationID == observationID }
    }

    func reset(startedAt: Date? = nil) {
        recentEvents.removeAll()
        resetObservation(startedAt: startedAt)
    }

    func beginObservation(at date: Date = Date()) {
        resetObservation(startedAt: date)
    }

    private func resetObservation(startedAt: Date?) {
        observationID = startedAt == nil ? nil : UUID()
        self.startedAt = startedAt
        endedAt = nil
        lastGO = nil
        lastPanic = nil
        goCount = 0
        startCount = 0
        stopCount = 0
        panicCount = 0
        gosSinceLastPanic = 0
        isIncomplete = false
        observedCueIDs.removeAll()
    }

    func endObservation(at date: Date = Date()) {
        guard startedAt != nil, endedAt == nil else { return }
        endedAt = date
    }

    func markIncomplete() {
        guard startedAt != nil, endedAt == nil else { return }
        isIncomplete = true
    }

    func record(_ message: OSCMessage, timestamp: Date = Date(), workspaceName: String? = nil) {
        guard startedAt != nil, endedAt == nil else { return }
        let kind: Event.Kind
        switch message.address {
        case "/qlab/event/workspace/go": kind = .go
        case "/qlab/event/workspace/cue/start": kind = .start
        case "/qlab/event/workspace/cue/stop": kind = .stop
        case "/qlab/event/workspace/panicAll": kind = .panic
        default: return
        }
        // Base cue broadcasts carry four strings. Detail broadcasts and malformed
        // packets cannot count as additional cue activity.
        if kind == .panic {
            guard message.arguments.isEmpty else { return }
        } else {
            guard message.arguments.count == 4,
                  message.arguments.allSatisfy({ $0.stringValue != nil }) else { return }
        }
        let strings = message.arguments.map { $0.stringValue ?? "" }
        let cueID = kind == .panic || strings[2].isEmpty ? nil : strings[2]
        let event = Event(
            timestamp: timestamp, kind: kind, cueID: cueID,
            cueNumber: kind == .panic ? "" : strings[0],
            cueName: kind == .panic ? "" : strings[1],
            observationID: observationID, workspaceName: workspaceName, detail: nil
        )
        switch kind {
        case .go:
            goCount += 1
            gosSinceLastPanic += 1
            lastGO = timestamp
        case .start: startCount += 1
        case .stop: stopCount += 1
        case .panic:
            panicCount += 1
            gosSinceLastPanic = 0
            lastPanic = timestamp
        default: return
        }
        if kind == .go || kind == .start, let cueID { observedCueIDs.insert(cueID) }
        append(event)
    }

    func recordLifecycle(
        _ kind: Event.Kind, workspaceName: String? = nil,
        detail: String? = nil, timestamp: Date = Date()
    ) {
        guard !kind.isCueEvent else { return }
        append(Event(
            timestamp: timestamp, kind: kind, cueID: nil, cueNumber: "", cueName: "",
            observationID: endedAt == nil ? observationID : nil,
            workspaceName: workspaceName, detail: detail
        ))
    }

    private func append(_ event: Event) {
        recentEvents.append(event)
        if recentEvents.count > 100 { recentEvents.removeFirst(recentEvents.count - 100) }
    }

    func activityInLastMinute(at date: Date) -> Int {
        currentObservationEvents.filter {
            ($0.kind == .go || $0.kind == .start)
                && $0.timestamp > date.addingTimeInterval(-60) && $0.timestamp <= date
        }.count
    }

    var recentRepeats: [Repeat] {
        let activity = currentObservationEvents.filter { $0.kind == .go }
        return Dictionary(grouping: activity.compactMap { event -> Event? in
            event.cueID == nil ? nil : event
        }, by: { $0.cueID! })
        .compactMap { id, events in
            guard events.count > 1, let event = events.last else { return nil }
            return Repeat(id: id, label: event.cueLabel.isEmpty ? id : event.cueLabel, count: events.count)
        }
        .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
}
