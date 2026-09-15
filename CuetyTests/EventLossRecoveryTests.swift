import Foundation
import Testing

@testable import Cuety

@Suite("Event loss recovery")
struct EventLossRecoveryTests {
    private let window = QLabClient.overflowEscalationWindow

    @Test("The first loss of a session resynchronizes")
    func firstLossResynchronizes() {
        #expect(QLabClient.recovery(after: nil, at: .now) == .resynchronize)
    }

    @Test("A second loss inside the window rebuilds the session")
    func repeatWithinWindowEscalates() {
        let first = ContinuousClock.now
        let again = first + window / 2

        #expect(QLabClient.recovery(after: first, at: again) == .rebuildSession)
    }

    @Test("A loss after the window has passed resynchronizes again")
    func lossAfterWindowDoesNotEscalate() {
        let first = ContinuousClock.now
        let later = first + window + .seconds(1)

        #expect(QLabClient.recovery(after: first, at: later) == .resynchronize)
    }

    @Test("Exactly one window later is treated as a fresh episode")
    func windowBoundaryIsExclusive() {
        let first = ContinuousClock.now

        #expect(QLabClient.recovery(after: first, at: first + window) == .resynchronize)
        #expect(
            QLabClient.recovery(after: first, at: first + window - .milliseconds(1))
                == .rebuildSession
        )
    }

    @Test("Two losses in the same instant escalate")
    func simultaneousLossesEscalate() {
        let now = ContinuousClock.now
        #expect(QLabClient.recovery(after: now, at: now) == .rebuildSession)
    }

    @Test("A cleared history resynchronizes even straight after an escalation")
    func clearedHistoryStartsFresh() {
        let escalatedAt = ContinuousClock.now
        let momentsLater = escalatedAt + .milliseconds(50)

        #expect(QLabClient.recovery(after: nil, at: momentsLater) == .resynchronize)
    }
}
