import Foundation
import ShowControlCore
import Testing

@testable import Cuety

@Suite("Event history")
@MainActor
struct EventHistoryTests {
    let start = Date(timeIntervalSince1970: 1000)

    private func cue(_ event: String, id: String = "cue-A") -> OSCMessage {
        OSCMessage("/qlab/event/workspace/\(event)", [
            .string("42"), .string("Thunder"), .string(id), .string("Audio")
        ])
    }

    @Test("Cue broadcasts retain valid events and reject malformed packets")
    func validCueEvents() {
        let history = EventHistory()
        history.beginObservation(at: start)
        history.record(cue("go"), timestamp: start)
        history.record(cue("go/number"), timestamp: start)
        history.record(OSCMessage("/qlab/event/workspace/go", [.string("42")]))
        history.record(cue("cue/start"), timestamp: start)
        history.record(cue("cue/stop"), timestamp: start)

        #expect(history.recentEvents.map(\.kind) == [.go, .start, .stop])
        #expect(history.recentEvents.first?.cueLabel == "42 · Thunder")
    }

    @Test("Lifecycle entries can surround a connection observation")
    func lifecycleEvents() {
        let history = EventHistory()
        history.recordLifecycle(.connecting, workspaceName: "W", timestamp: start)
        history.beginObservation(at: start)
        history.recordLifecycle(.connected, workspaceName: "Show", timestamp: start)
        history.recordLifecycle(.missedEvents, workspaceName: "Show", detail: "3 events", timestamp: start)
        history.recordLifecycle(.go, timestamp: start)

        #expect(history.recentEvents.count == 3)
        #expect(history.recentEvents.first?.observationID == nil)
        #expect(history.recentEvents.last?.detail == "3 events")

        history.endObservation(at: start.addingTimeInterval(1))
        history.recordLifecycle(.reconnecting, workspaceName: "W", timestamp: start.addingTimeInterval(2))
        history.markIncomplete()
        #expect(history.recentEvents.last?.observationID == nil)
        #expect(!history.isIncomplete)
    }

    @Test("History is bounded and can be cleared without ending the observation")
    func boundedAndClearable() {
        let history = EventHistory()
        history.beginObservation(at: start)
        for index in 0..<120 {
            history.record(cue("go", id: "cue-\(index)"), timestamp: start.addingTimeInterval(Double(index)))
        }

        #expect(history.recentEvents.count == 100)
        #expect(history.recentEvents.first?.cueID == "cue-20")
        history.clearRecentEvents()
        #expect(history.recentEvents.isEmpty)
        history.record(cue("go"), timestamp: start)
        #expect(history.recentEvents.count == 1)
    }

    @Test("Reset removes retained events and incomplete state")
    func reset() {
        let history = EventHistory()
        history.beginObservation(at: start)
        history.record(cue("go"), timestamp: start)
        history.markIncomplete()
        history.reset()

        #expect(history.recentEvents.isEmpty)
        #expect(history.observationID == nil)
        #expect(!history.isIncomplete)
    }
}
