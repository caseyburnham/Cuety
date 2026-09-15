import Foundation
import Testing

@testable import Cuety

@Suite("Preference limits")
@MainActor
struct PreferenceLimitsTests {
    private func preferences() throws -> Preferences {
        Preferences(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    }


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


    @Test("An out-of-range stored value is clamped as it is read")
    func loadingClampsStoredValues() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
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
