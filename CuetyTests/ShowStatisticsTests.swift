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
}
