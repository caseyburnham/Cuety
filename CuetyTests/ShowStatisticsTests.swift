import Foundation
import ShowControlCore
import Testing

@testable import Cuety

@Suite("Observed show statistics")
@MainActor
struct ShowStatisticsTests {
    let start = Date(timeIntervalSince1970: 1000)

    private func cue(_ event: String, id: String = "cue-A") -> OSCMessage {
        OSCMessage("/qlab/event/workspace/\(event)", [.string("42"), .string("Thunder"), .string(id), .string("Audio")])
    }

    @Test("Base broadcasts count once and keep GO and start event totals separate")
    func exactBroadcasts() {
        let stats = ShowStatistics()
        stats.reset(startedAt: start)
        stats.record(cue("go"), timestamp: start)
        stats.record(cue("go/number"), timestamp: start)
        stats.record(OSCMessage("/qlab/event/workspace/go", [.string("42")]))
        stats.record(cue("cue/start"), timestamp: start)
        stats.record(cue("cue/stop"), timestamp: start)
        #expect(stats.goCount == 1)
        #expect(stats.startCount == 1)
        #expect(stats.stopCount == 1)
        #expect(stats.uniqueCueCount == 1)
        #expect(stats.recentRepeats.isEmpty)
        stats.record(cue("go"), timestamp: start.addingTimeInterval(1))
        #expect(stats.recentRepeats.first?.count == 2)
    }

    @Test("A panic resets the streak; a monitoring reset forgets the prior session")
    func panicAndReset() {
        let stats = ShowStatistics()
        stats.reset(startedAt: start)
        stats.record(cue("go"), timestamp: start)
        #expect(stats.gosSinceLastPanic == 1)
        #expect(stats.lastPanic == nil)
        stats.record(OSCMessage("/qlab/event/workspace/panicAll", [.string("invalid")]))
        #expect(stats.panicCount == 0)
        stats.record(OSCMessage("/qlab/event/workspace/panicAll"), timestamp: start.addingTimeInterval(2))
        #expect(stats.gosSinceLastPanic == 0)
        #expect(stats.panicCount == 1)
        stats.record(cue("go"), timestamp: start.addingTimeInterval(3))
        #expect(stats.gosSinceLastPanic == 1)
        stats.markIncomplete()
        stats.reset()
        #expect(stats.startedAt == nil)
        #expect(stats.lastPanic == nil)
        #expect(stats.goCount == 0)
        #expect(!stats.isIncomplete)
        #expect(stats.recentEvents.isEmpty)
        stats.record(cue("go"))
        #expect(stats.goCount == 0)
    }

    @Test("History is bounded while session totals survive eviction")
    func boundedHistory() {
        let stats = ShowStatistics()
        stats.reset(startedAt: start)
        for index in 0..<120 {
            stats.record(cue("go", id: "cue-\(index)"), timestamp: start.addingTimeInterval(Double(index)))
        }
        #expect(stats.recentEvents.count == 100)
        #expect(stats.goCount == 120)
        #expect(stats.uniqueCueCount == 120)
        #expect(stats.activityInLastMinute(at: start.addingTimeInterval(119)) == 60)
    }

    @Test("Ended observation rejects late broadcasts and freezes its end date")
    func endObservation() {
        let stats = ShowStatistics()
        stats.reset(startedAt: start)
        stats.endObservation(at: start.addingTimeInterval(10))
        stats.endObservation(at: start.addingTimeInterval(20))
        stats.record(cue("go"))
        #expect(stats.endedAt == start.addingTimeInterval(10))
        #expect(stats.goCount == 0)
    }

    @Test("A new observation retains history while its activity and counters start fresh")
    func retainedHistoryAcrossObservations() {
        let stats = ShowStatistics()
        stats.beginObservation(at: start)
        let firstObservation = stats.observationID
        stats.record(cue("go"), timestamp: start, workspaceName: "First Show")
        stats.record(cue("go"), timestamp: start.addingTimeInterval(1), workspaceName: "First Show")
        stats.markIncomplete()
        stats.endObservation(at: start.addingTimeInterval(2))

        stats.beginObservation(at: start.addingTimeInterval(3))
        #expect(stats.observationID != firstObservation)
        #expect(stats.recentEvents.count == 2)
        #expect(stats.recentEvents.first?.workspaceName == "First Show")
        #expect(stats.currentObservationEvents.isEmpty)
        #expect(stats.activityInLastMinute(at: start.addingTimeInterval(3)) == 0)
        #expect(stats.recentRepeats.isEmpty)
        #expect(stats.goCount == 0)
        #expect(stats.gosSinceLastPanic == 0)
        #expect(stats.uniqueCueCount == 0)
        #expect(!stats.isIncomplete)

        stats.record(cue("go"), timestamp: start.addingTimeInterval(4), workspaceName: "Second Show")
        #expect(stats.goCount == 1)
        #expect(stats.currentObservationEvents.count == 1)
        #expect(stats.activityInLastMinute(at: start.addingTimeInterval(5)) == 1)
        #expect(stats.recentRepeats.isEmpty)
        #expect(stats.recentEvents.last?.workspaceName == "Second Show")
    }

    @Test("Lifecycle entries work outside observations without counting as cue activity")
    func lifecycleDoesNotCountAsActivity() {
        let stats = ShowStatistics()
        stats.recordLifecycle(.connecting, workspaceName: "W", timestamp: start)
        #expect(stats.recentEvents.first?.observationID == nil)
        stats.beginObservation(at: start)
        stats.recordLifecycle(.connected, workspaceName: "Show", timestamp: start)
        stats.recordLifecycle(.missedEvents, workspaceName: "Show", detail: "3 events", timestamp: start)
        stats.recordLifecycle(.go, timestamp: start)
        #expect(stats.recentEvents.count == 3)
        #expect(stats.currentObservationEvents.count == 2)
        #expect(stats.recentEvents.last?.detail == "3 events")
        #expect(stats.goCount == 0)
        #expect(stats.startCount == 0)
        #expect(stats.stopCount == 0)
        #expect(stats.panicCount == 0)
        #expect(stats.gosSinceLastPanic == 0)
        #expect(stats.uniqueCueCount == 0)
        #expect(stats.activityInLastMinute(at: start) == 0)
        #expect(stats.recentRepeats.isEmpty)

        stats.endObservation(at: start.addingTimeInterval(1))
        stats.recordLifecycle(.reconnecting, workspaceName: "W", timestamp: start.addingTimeInterval(2))
        #expect(stats.recentEvents.last?.observationID == nil)
        stats.markIncomplete()
        #expect(!stats.isIncomplete)
    }

    @Test("Cue and lifecycle entries share one bounded history across observations")
    func boundedMixedHistory() {
        let stats = ShowStatistics()
        stats.beginObservation(at: start)
        for index in 0..<60 {
            stats.record(cue("go", id: "cue-\(index)"), timestamp: start.addingTimeInterval(Double(index)))
        }
        stats.endObservation()
        for index in 0..<45 {
            stats.recordLifecycle(.reconnecting, detail: "Attempt \(index)")
        }
        #expect(stats.recentEvents.count == 100)
        #expect(stats.recentEvents.first?.cueID == "cue-5")
        #expect(stats.goCount == 60)
        #expect(stats.currentObservationEvents.count == 55)
        stats.reset()
        #expect(stats.recentEvents.isEmpty)
        #expect(stats.currentObservationEvents.isEmpty)
    }
}
