import Foundation
import Testing

@testable import Cuety

/// The policy for recovering from a full event buffer.
///
/// Asserted directly rather than through an overflow. Reaching this via the
/// real trigger means stalling the client's own event consumer, which nothing
/// outside the client can do — and a test-only hook that faked the overflow
/// would be testing the fake rather than the rule. The rule is what matters:
/// `/updates` and `/listen/playhead` can lapse without QLab saying so, and
/// this is the only thing between that and a display that quietly stops
/// changing.
@Suite("Event loss recovery")
struct EventLossRecoveryTests {
    private let window = QLabClient.overflowEscalationWindow

    @Test("The first loss of a session resynchronizes")
    func firstLossResynchronizes() {
        // Nothing to escalate from. A burst is a busy moment, and refetching
        // the cue tree is both the cheap fix and the right one.
        #expect(QLabClient.recovery(after: nil, at: .now) == .resynchronize)
    }

    @Test("A second loss inside the window rebuilds the session")
    func repeatWithinWindowEscalates() {
        let first = ContinuousClock.now
        let again = first + window / 2

        // Resynchronizing was already tried and did not hold, which is the
        // signature of a lapsed subscription — a failure no amount of
        // refetching repairs.
        #expect(QLabClient.recovery(after: first, at: again) == .rebuildSession)
    }

    @Test("A loss after the window has passed resynchronizes again")
    func lossAfterWindowDoesNotEscalate() {
        let first = ContinuousClock.now
        let later = first + window + .seconds(1)

        // Two unrelated busy moments an hour apart are not evidence of a
        // broken subscription, and rebuilding the session flickers the cue
        // display through `connecting` for nothing.
        #expect(QLabClient.recovery(after: first, at: later) == .resynchronize)
    }

    /// The window is a half-open interval, so the boundary has to be stated.
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
        // Recovery records its own instant before acting, so a report landing
        // in the same instant is a repeat rather than a first.
        let now = ContinuousClock.now
        #expect(QLabClient.recovery(after: now, at: now) == .rebuildSession)
    }

    /// Escalation is once, not forever: a rebuilt session starts clean.
    ///
    /// `tearDownSession` clears `lastOverflowRecovery`, so a reconnect cannot
    /// arrive already one strike down and immediately rebuild itself again.
    /// This is the rule that makes that reset correct rather than incidental.
    @Test("A cleared history resynchronizes even straight after an escalation")
    func clearedHistoryStartsFresh() {
        let escalatedAt = ContinuousClock.now
        let momentsLater = escalatedAt + .milliseconds(50)

        #expect(QLabClient.recovery(after: nil, at: momentsLater) == .resynchronize)
    }
}
