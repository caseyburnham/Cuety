import Foundation
import Testing

@testable import Cuety

@Suite("Readouts outside the window")
@MainActor
struct MenuBarReadoutTests {
    private func makePreferences() throws -> Preferences {
        Preferences(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    }

    private func makeModel() throws -> AppModel {
        AppModel(preferences: try makePreferences())
    }


    @Test("Neither readout is on until it is asked for")
    func readoutsAreOffByDefault() throws {
        let preferences = try makePreferences()

        #expect(!preferences.showsMenuBarExtra)
        #expect(!preferences.showsDockBadge)
        #expect(preferences.menuBarReadout == .cueNumber)
    }

    @Test("The chosen readout survives a relaunch")
    func readoutPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)

        preferences.showsMenuBarExtra = true
        preferences.menuBarReadout = .heartbeat
        preferences.showsDockBadge = true

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.showsMenuBarExtra)
        #expect(reloaded.menuBarReadout == .heartbeat)
        #expect(reloaded.showsDockBadge)
    }

    @Test("An unrecognised stored readout falls back to the default")
    func unknownReadoutFallsBack() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("semaphore", forKey: "menuBarReadout")

        #expect(Preferences(defaults: defaults).menuBarReadout == .default)
    }


    @Test("An unasked-for badge is no badge")
    func badgeIsAbsentUntilEnabled() throws {
        let model = try makeModel()

        #expect(!model.preferences.showsDockBadge)
        #expect(model.dockBadgeLabel == nil)
    }

    @Test("With no live session there is nothing to badge")
    func badgeIsAbsentWithoutALiveSession() throws {
        let model = try makeModel()
        model.preferences.showsDockBadge = true

        #expect(!model.client.status.hasLiveData)
        #expect(model.standbyCue == nil)
        #expect(model.dockBadgeLabel == nil)
    }


    @Test(
        "Every readout is named, described, and stably spelled",
        arguments: MenuBarReadout.allCases
    )
    func everyReadoutCanBeOffered(readout: MenuBarReadout) {
        #expect(!readout.title.isEmpty)
        #expect(!readout.detail.isEmpty)
        #expect(MenuBarReadout(rawValue: readout.rawValue) == readout)
    }
}
