import Foundation
import Testing

@testable import Cuety

@Suite("Readouts outside the window")
@MainActor
struct MenuBarReadoutTests {
    private func makePreferences() throws -> Preferences {
        Preferences(defaults: EphemeralDefaults())
    }

    @Test("The menu bar readout is off until it is asked for")
    func readoutsAreOffByDefault() throws {
        let preferences = try makePreferences()

        #expect(!preferences.showsMenuBarExtra)
        #expect(preferences.menuBarReadout == .cueNumber)
    }

    @Test("The chosen readout survives a relaunch")
    func readoutPersists() throws {
        let defaults = EphemeralDefaults()
        let preferences = Preferences(defaults: defaults)

        preferences.showsMenuBarExtra = true
        preferences.menuBarReadout = .heartbeat

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.showsMenuBarExtra)
        #expect(reloaded.menuBarReadout == .heartbeat)
    }

    @Test("An unrecognised stored readout falls back to the default")
    func unknownReadoutFallsBack() throws {
        let defaults = EphemeralDefaults()
        defaults.set("semaphore", forKey: "menuBarReadout")

        #expect(Preferences(defaults: defaults).menuBarReadout == .default)
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
