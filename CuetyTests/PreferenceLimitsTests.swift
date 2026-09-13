import Foundation
import Testing

@testable import Cuety

/// The bounds on every numeric preference, enforced at both ends.
///
/// ``Preferences/Limits`` exists so that a Settings control's range cannot
/// drift from what the app will actually accept, and so that a value which
/// never went through a Settings control at all — written by an earlier build,
/// by `defaults write`, or by a synced preference file — cannot reach the
/// networking layer. A `requestTimeout` of 0 fails every request immediately
/// and a `heartbeatInterval` of 0 turns the heartbeat into a tight loop aimed
/// at a show control machine, so both halves are worth holding to.
///
/// The assignment tests earn their keep twice over. Clamping first lived in
/// each property's `didSet`, which self-assigned to store the clamped value —
/// correct for a plain stored property, and fatal here: `@Observable` rewrites
/// stored properties into computed ones over hidden storage that carries the
/// observer, so the self-assignment re-entered the setter and recursed until
/// the stack was gone. The app died on the first Stepper click. Any return of
/// that shape crashes these tests rather than the operator's machine.
@Suite("Preference limits")
@MainActor
struct PreferenceLimitsTests {
    private func preferences() throws -> Preferences {
        Preferences(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    }

    // MARK: - Assignment

    @Test("A value above the maximum is held to it, and settles")
    func assignmentClampsHigh() throws {
        let preferences = try preferences()

        preferences.drawerRowsAboveCount = 99
        preferences.drawerRowsBelowCount = 99
        preferences.defaultPort = 70_000
        preferences.heartbeatInterval = 600
        preferences.requestTimeout = 600

        #expect(preferences.drawerRowsAboveCount == Preferences.Limits.drawerRows.upperBound)
        #expect(preferences.drawerRowsBelowCount == Preferences.Limits.drawerRows.upperBound)
        #expect(preferences.defaultPort == Preferences.Limits.port.upperBound)
        #expect(preferences.heartbeatInterval == Preferences.Limits.heartbeatInterval.upperBound)
        #expect(preferences.requestTimeout == Preferences.Limits.requestTimeout.upperBound)
    }

    @Test("A value below the minimum is held to it")
    func assignmentClampsLow() throws {
        let preferences = try preferences()

        preferences.drawerRowsAboveCount = -4
        preferences.defaultPort = 0
        preferences.heartbeatInterval = 0
        preferences.requestTimeout = 0

        #expect(preferences.drawerRowsAboveCount == Preferences.Limits.drawerRows.lowerBound)
        #expect(preferences.defaultPort == Preferences.Limits.port.lowerBound)
        #expect(preferences.heartbeatInterval == Preferences.Limits.heartbeatInterval.lowerBound)
        #expect(preferences.requestTimeout == Preferences.Limits.requestTimeout.lowerBound)
    }

    @Test("A value inside the range is stored exactly as offered")
    func inRangeValuesPassThrough() throws {
        let preferences = try preferences()

        preferences.drawerRowsAboveCount = 4
        preferences.defaultPort = 53_001
        preferences.heartbeatInterval = 2.5
        preferences.requestTimeout = 12

        #expect(preferences.drawerRowsAboveCount == 4)
        #expect(preferences.defaultPort == 53_001)
        #expect(preferences.heartbeatInterval == 2.5)
        #expect(preferences.requestTimeout == 12)
    }

    /// What was clamped is what persists — not the value that was offered.
    @Test("The clamped value is the one written to the store")
    func theClampedValueIsPersisted() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)

        preferences.drawerRowsAboveCount = 99
        preferences.requestTimeout = 600

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.drawerRowsAboveCount == Preferences.Limits.drawerRows.upperBound)
        #expect(reloaded.requestTimeout == Preferences.Limits.requestTimeout.upperBound)
    }

    // MARK: - Loading

    /// The half the setters cannot cover: a value that was already in the store
    /// was never assigned, so only the loader can catch it.
    @Test("An out-of-range stored value is clamped as it is read")
    func loadingClampsStoredValues() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        // Spelled as they are persisted, which is not how the properties are
        // named — see ``Preferences.Key``.
        defaults.set(99, forKey: "drawerPreviousCount")
        defaults.set(-1, forKey: "drawerUpcomingCount")
        defaults.set(70_000, forKey: "defaultPort")
        defaults.set(0.0, forKey: "heartbeatInterval")
        defaults.set(600.0, forKey: "requestTimeout")

        let preferences = Preferences(defaults: defaults)

        #expect(preferences.drawerRowsAboveCount == Preferences.Limits.drawerRows.upperBound)
        #expect(preferences.drawerRowsBelowCount == Preferences.Limits.drawerRows.lowerBound)
        #expect(preferences.defaultPort == Preferences.Limits.port.upperBound)
        #expect(preferences.heartbeatInterval == Preferences.Limits.heartbeatInterval.lowerBound)
        #expect(preferences.requestTimeout == Preferences.Limits.requestTimeout.upperBound)
    }

    @Test("An empty store loads the documented defaults")
    func emptyStoreLoadsDefaults() throws {
        let preferences = try preferences()

        #expect(preferences.drawerRowsAboveCount == 3)
        #expect(preferences.drawerRowsBelowCount == 3)
        #expect(preferences.defaultPort == Int(QLabServer.defaultPort))
        #expect(preferences.heartbeatInterval == 5)
        #expect(preferences.requestTimeout == 5)
    }

    // MARK: - Observation

    /// Clamping moved these properties from stored to computed, and a computed
    /// property is not itself tracked by `@Observable` — it is tracked through
    /// the storage its getter reads. Settings would go quiet if that storage
    /// were ever marked `@ObservationIgnored`, and quietly: every value would
    /// still be correct, the panel just would not redraw.
    @Test("Changing a clamped preference still notifies observers")
    func clampedPropertiesRemainObservable() async throws {
        let preferences = try preferences()

        await confirmation("observers were notified") { notified in
            withObservationTracking {
                _ = preferences.drawerRowsAboveCount
            } onChange: {
                notified()
            }

            preferences.drawerRowsAboveCount = 7
        }
    }
}
