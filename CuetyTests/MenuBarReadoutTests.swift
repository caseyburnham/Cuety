import Foundation
import Testing

@testable import Cuety

/// The readouts Cuety puts outside its own window: the menu bar item and the
/// Dock badge.
///
/// Both are read at a glance, and neither has room beside it for a caveat. So
/// the property worth holding to is that they say *nothing* rather than
/// something stale — see ``AppModel/standbyCue``. The live half of that
/// contract is asserted against a genuinely dropped session in
/// ``QLabDisconnectTests``, where the fake QLab lives; what is here is the
/// plumbing around it.
@Suite("Readouts outside the window")
@MainActor
struct MenuBarReadoutTests {
    private func makePreferences() throws -> Preferences {
        Preferences(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    }

    private func makeModel() throws -> AppModel {
        AppModel(preferences: try makePreferences())
    }

    // MARK: - Defaults

    /// Both readouts take space from outside the app — the menu bar is shared
    /// with every other app on the machine — so neither appears until the
    /// operator asks for it.
    @Test("Neither readout is on until it is asked for")
    func readoutsAreOffByDefault() throws {
        let preferences = try makePreferences()

        #expect(!preferences.showsMenuBarExtra)
        #expect(!preferences.showsDockBadge)
        // And when the menu bar item is switched on, it starts as the thing
        // the app is for.
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

    /// A readout spelling this build does not know — written by an earlier
    /// one, by `defaults write`, or by a synced preference file — must not
    /// leave the menu bar item with nothing to draw.
    @Test("An unrecognised stored readout falls back to the default")
    func unknownReadoutFallsBack() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("semaphore", forKey: "menuBarReadout")

        #expect(Preferences(defaults: defaults).menuBarReadout == .default)
    }

    // MARK: - The Dock badge

    @Test("An unasked-for badge is no badge")
    func badgeIsAbsentUntilEnabled() throws {
        let model = try makeModel()

        #expect(!model.preferences.showsDockBadge)
        #expect(model.dockBadgeLabel == nil)
    }

    /// The guard that does the work. `hasLiveData` is false here because
    /// nothing has connected at all, which is the same question the badge asks
    /// after a session drops.
    @Test("With no live session there is nothing to badge")
    func badgeIsAbsentWithoutALiveSession() throws {
        let model = try makeModel()
        model.preferences.showsDockBadge = true

        #expect(!model.client.status.hasLiveData)
        #expect(model.standbyCue == nil)
        #expect(model.dockBadgeLabel == nil)
    }

    // MARK: - Every readout can be offered

    /// ``MenuBarReadout`` is persisted by raw value and offered in a Settings
    /// picker, so every case needs a name to appear under, a sentence
    /// explaining it, and a spelling that does not move — renaming a case
    /// without keeping its raw value would silently reset the operator's
    /// choice on the next launch.
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
