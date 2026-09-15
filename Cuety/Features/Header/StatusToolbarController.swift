import AppKit
import SwiftUI

/// Everything the main window's toolbar draws, as a value.
///
/// A snapshot rather than a reference to ``AppModel``, so the AppKit side has
/// no opinion about observation: SwiftUI notices the model changed, rebuilds
/// this, and hands it over. ``StatusToolbar`` is where that happens.
struct StatusToolbarReadout: Equatable {
    var keepsDisplayAwake: Bool
    var heartbeatSymbol: String
    var heartbeatTint: Color
    /// Carried so a *new* heartbeat can be told from a redraw for some other
    /// reason. The glyph bounces on the change, not on the value.
    var heartbeatCount: Int
    var heartbeatSummary: String
    var status: ConnectionStatus
    /// Whether a refresh is running, which the Refresh item shows as a spinner.
    var isRefreshing: Bool
    var canRefresh: Bool
    /// Written to `NSWindow` directly. Declaring these with `.navigationTitle`
    /// put a leading titlebar accessory on the window, and that accessory is
    /// what left the toolbar with a trailing strip the width of its own items.
    var windowTitle: String
    var windowSubtitle: String
}

/// What the toolbar's buttons do.
///
/// Closures rather than a reference to the model, because two of them are
/// `openWindow` calls and that only exists in the SwiftUI environment.
struct StatusToolbarActions {
    var toggleKeepAwake: () -> Void = {}
    var openActivityLog: () -> Void = {}
    var openConnectionInspector: () -> Void = {}
    var refresh: () -> Void = {}
}

private extension NSToolbarItem.Identifier {
    static let cuetyRefresh = Self("com.ivxx.Cuety.toolbar.refresh")
    static let cuetyKeepAwake = Self("com.ivxx.Cuety.toolbar.keepAwake")
    static let cuetyActivityLog = Self("com.ivxx.Cuety.toolbar.activityLog")
    static let cuetyConnectionStatus = Self("com.ivxx.Cuety.toolbar.connectionStatus")
}

/// Owns the main window's `NSToolbar`, builds its items, and keeps their
/// glyphs matching the session.
///
/// A real `NSToolbar` with a delegate, rather than SwiftUI `ToolbarContent`.
/// The SwiftUI version had gone two rounds with the same problem: a toolbar
/// button whose label is anything but a plain `Label` is treated as custom
/// content, and custom content does not get the standard toolbar button
/// treatment — no hover highlight, no press response, no Liquid Glass. Every
/// item here needs a tinted, animating glyph, so every item was custom
/// content. Driving `NSToolbarItem` directly means the buttons behave the way
/// they do in Finder because they *are* what Finder uses.
@MainActor
final class StatusToolbarController: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar

    /// Reassigned on every SwiftUI update, so a click never runs a closure
    /// captured from an earlier `body`.
    var actions = StatusToolbarActions()

    /// What the buttons currently show.
    ///
    /// Kept so an update only touches what actually changed. Re-setting a
    /// glyph restarts its transition, and with heartbeats arriving about once
    /// a second an unconditional refresh would leave the toolbar permanently
    /// mid-animation.
    private var applied: StatusToolbarReadout?

    // Weak throughout: the toolbar owns its items and the items own these
    // buttons. A replaced item takes its button with it, and these go nil.
    private weak var refreshButton: SymbolToolbarButton?
    private weak var keepAwakeButton: SymbolToolbarButton?
    private weak var heartbeatButton: SymbolToolbarButton?
    private weak var statusButton: SymbolToolbarButton?

    override init() {
        toolbar = NSToolbar(identifier: "com.ivxx.Cuety.toolbar")
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Off deliberately, which is the one place this departs from a stock
        // toolbar. Every item is either a live readout or the sidebar control;
        // an operator who dragged the connection status off the toolbar during
        // a show would have no way left to see that the link had dropped.
        toolbar.allowsUserCustomization = false
    }

    // MARK: Installing

    /// Puts this toolbar on `window`, and puts it back if anything replaces it.
    ///
    /// Checked on every update rather than done once. SwiftUI installs a
    /// toolbar of its own on a window whose content asks for one, and while
    /// ``MainWindowView`` asks for none, that is a guarantee about today's
    /// view tree rather than about SwiftUI. The identity test makes this a
    /// no-op the rest of the time.
    func install(in window: NSWindow) {
        // Held so ``apply(_:)`` can write the title, which is the window's
        // rather than the toolbar's but arrives in the same readout.
        self.window = window
        guard window.toolbar !== toolbar else { return }
        window.toolbar = toolbar
    }

    private weak var window: NSWindow?

    // MARK: Updating

    /// Matches the buttons to `readout`.
    func apply(_ readout: StatusToolbarReadout) {
        // Only the effects that run off a *change* are gated here. The glyph
        // transitions handle Reduce Motion themselves, inside ``ToolbarGlyph``.
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previous = applied
        applied = readout

        if let window, previous?.windowTitle != readout.windowTitle {
            window.title = readout.windowTitle
        }
        if let window, previous?.windowSubtitle != readout.windowSubtitle {
            window.subtitle = readout.windowSubtitle
        }

        if let refreshButton {
            if previous?.isRefreshing != readout.isRefreshing {
                refreshButton.setSpinning(readout.isRefreshing)
                refreshButton.toolTip = readout.isRefreshing
                    ? "Searching. Click again to start over."
                    : "Re-ask every server what it has open, and rebuild the current QLab connection."
            }
            // The one item here that is ever disabled, and set directly rather
            // than through toolbar validation, which `autovalidates = false`
            // turns off. Refresh rebuilds the live session, so offering it
            // mid-connect would tear down the attempt it was racing; it stays
            // enabled while *refreshing* on purpose — see ``AppModel/canRefresh``.
            if previous?.canRefresh != readout.canRefresh {
                refreshButton.isEnabled = readout.canRefresh
            }
        }

        if let keepAwakeButton, previous?.keepsDisplayAwake != readout.keepsDisplayAwake {
            let isOn = readout.keepsDisplayAwake
            // The bezel's own on state, which is what makes this read as a
            // toggle rather than as a button that happens to change picture.
            keepAwakeButton.state = isOn ? .on : .off
            // The glyph brightens with the state: `sun.min` when the display
            // is free to sleep, `sun.max.fill` when it is being held awake.
            // On, the bezel fills, and a template-black glyph on a filled
            // bezel is close to unreadable. This is the system's colour for
            // content sitting on a filled selection — white, in both
            // appearances — rather than a literal white of our own. Set before
            // the symbol, for the reason the heartbeat's is.
            keepAwakeButton.glyphTint = isOn
                ? Color(nsColor: .alternateSelectedControlTextColor)
                : nil
            keepAwakeButton.setSymbol(isOn ? "sun.max.fill" : "sun.min")
            keepAwakeButton.toolTip = isOn
                ? "The display is being kept awake."
                : "The display can sleep."
            keepAwakeButton.setAccessibilityValue(isOn ? "On" : "Off")
        }

        if let heartbeatButton {
            // Tint before symbol, so the glyph arriving through the transition
            // is already the colour it is going to end up. Losing the session
            // changes both at once — pink heart to grey struck-through heart —
            // and recolouring afterwards means watching the new glyph change
            // colour once it is already in place.
            if previous?.heartbeatTint != readout.heartbeatTint {
                heartbeatButton.glyphTint = readout.heartbeatTint
            }

            heartbeatButton.setSymbol(readout.heartbeatSymbol)

            if previous?.heartbeatSummary != readout.heartbeatSummary {
                heartbeatButton.toolTip = "Activity Log. " + readout.heartbeatSummary
                heartbeatButton.setAccessibilityValue(readout.heartbeatSummary)
            }

            // Driven off the count rather than a timer, so the glyph is a true
            // report of the link: when QLab stops answering it visibly stops
            // moving instead of animating reassuringly. Skipped when there is
            // no previous readout, so installing the toolbar doesn't look like
            // a heartbeat arriving.
            if animates, let previous, previous.heartbeatCount != readout.heartbeatCount {
                heartbeatButton.bounce()
            }
        }

        if let statusButton, previous?.status != readout.status {
            let status = readout.status
            statusButton.glyphTint = status.tint
            statusButton.setSymbol(status.toolbarSymbol)
            // Conveys ongoing work while connecting, and stops once settled.
            statusButton.setWorking(animates && status.isTransitional)
            statusButton.toolTip = "\(status.title). \(status.detail)"
            statusButton.setAccessibilityValue(status.title)
        }
    }

    // MARK: NSToolbarDelegate

    /// Two titlebar sections, split by the tracking separator.
    ///
    /// **Over the sidebar:** Refresh, then the sidebar toggle, pushed to the
    /// *trailing* end of their section by the leading `.flexibleSpace`. That
    /// space is the whole reason the toggle slides out with the sidebar
    /// instead of sitting still while it goes: left-aligned, the items stayed
    /// pinned by the traffic lights and only jumped once the collapsing
    /// section got too narrow to hold them. Right-aligned, the section
    /// shrinking *is* the items moving.
    ///
    /// Measured against Mail rather than guessed at: with its sidebar open,
    /// Mail's toggle hugs the divider, and collapsing the sidebar slides it
    /// left to settle beside the traffic lights. This produces both ends of
    /// that.
    ///
    /// Refresh is on this side because what it refreshes *is* the sidebar — it
    /// re-asks every server what it has open — so it travels with the thing it
    /// acts on.
    ///
    /// **Over the detail:** keep-awake, then the two readouts.
    ///
    /// Every `.space` here is load-bearing. macOS draws each *run of adjacent
    /// items* as one grouped capsule, so the spaces are the grouping: without
    /// them, Refresh is welded to the sidebar toggle, and keep-awake reads as
    /// a third status glyph. Refresh and keep-awake were briefly adjacent and
    /// got drawn as a single control pair — two actions with nothing whatever
    /// to do with each other.
    ///
    /// The **doubled** space before the toggle is not a typo. One is enough
    /// while the sidebar is open, but collapsing it re-flows this section and
    /// a single space comes back narrower than the width at which macOS stops
    /// grouping: the two circular bezels merged into one capsule with a
    /// pinched waist, which read as the buttons half-morphing together. Two
    /// spaces survive the re-flow, and the open state does not look airy for
    /// it — both were checked in both states.
    ///
    /// The `.flexibleSpace` earns its place here in a way it did not in the
    /// detail section, where the window title had already taken the slack and
    /// removing it changed nothing.
    ///
    /// `.toggleSidebar` is the system's own item, not Cuety's: it sends
    /// `toggleSidebar:` down the responder chain, where
    /// ``MainSplitViewController`` answers it as any `NSSplitViewController`
    /// does, and reports the result back to ``AppModel/isSidebarVisible`` — so
    /// the model still hears about it without Cuety owning the control.
    ///
    /// `.sidebarTrackingSeparator` is what puts the toggle *over* the sidebar,
    /// the way Finder's is, and it works now that
    /// ``MainSplitViewController`` is the window's `contentViewController`.
    ///
    /// It could not before. A tracking separator aligns itself with a titlebar
    /// *section*, and a window only has one of those when its content is an
    /// `NSSplitViewController` whose sidebar `NSSplitViewItem` has
    /// `behavior == .sidebar`. Under `NavigationSplitView` the content
    /// controller was SwiftUI's hosting controller with a bare `NSSplitView`
    /// inside it, so the separator reported `isVisible == false` and drew
    /// nothing — while still taking up a position, which laid everything
    /// behind it out in the detail region.
    private static let identifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .cuetyRefresh,
        .space,
        .space,
        .toggleSidebar,
        .sidebarTrackingSeparator,
        .cuetyKeepAwake,
        .space,
        .cuetyActivityLog,
        .cuetyConnectionStatus,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    /// Every symbol the connection glyph can show, so the button can be sized
    /// to the widest of them.
    ///
    /// Written as cases rather than as symbol names so ``ConnectionStatus``
    /// stays the only place that decides what a state looks like. Adding a
    /// case means adding a line here; *changing a glyph* does not, which is
    /// the drift that previously left the toolbar showing a retired symbol.
    private static let statusCases: [ConnectionStatus] = [
        .offline,
        .connecting,
        .reconnecting(attempt: 1, reason: ""),
        .needsPasscode(rejected: false),
        .connected,
        .degraded(reason: ""),
        .workspaceClosed,
        .failed(reason: ""),
    ]

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // A fresh instance every time, as `NSToolbarDelegate` requires — items
        // are not to be recycled. The button is captured weakly on the way
        // out, so whichever item the toolbar is actually showing is the one
        // ``apply(_:)`` updates.
        switch identifier {
        case .cuetyRefresh:
            let (item, button) = makeItem(
                identifier: identifier,
                label: "Refresh Connections",
                symbols: ["arrow.clockwise"],
                action: #selector(refresh)
            )
            button.setAccessibilityHelp("Re-asks every server what it has open")
            if flag { refreshButton = button }
            return item

        case .cuetyKeepAwake:
            let (item, button) = makeItem(
                identifier: identifier,
                label: "Keep Display Awake",
                symbols: ["sun.min", "sun.max.fill"],
                action: #selector(toggleKeepAwake)
            )
            // Push-on-push-off so the bezel carries the on state itself,
            // rather than the glyph being the only thing that says so.
            button.setButtonType(.pushOnPushOff)
            if flag { keepAwakeButton = button }
            return item

        case .cuetyActivityLog:
            let (item, button) = makeItem(
                identifier: identifier,
                label: "Activity Log",
                symbols: ["heart.fill", "heart.slash.fill"],
                action: #selector(openActivityLog)
            )
            button.setAccessibilityHelp("Opens the activity log")
            if flag { heartbeatButton = button }
            return item

        case .cuetyConnectionStatus:
            let (item, button) = makeItem(
                identifier: identifier,
                label: "Connection Status",
                symbols: Self.statusCases.map(\.toolbarSymbol),
                action: #selector(openConnectionInspector)
            )
            button.setAccessibilityHelp("Opens the connection status window")
            if flag { statusButton = button }
            return item

        default:
            // The sidebar toggle and the spacers. The toolbar builds those
            // itself, which is the point of using their identifiers rather than
            // items of Cuety's own.
            return nil
        }
    }

    private func makeItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbols: [String],
        action: Selector
    ) -> (NSToolbarItem, SymbolToolbarButton) {
        let button = SymbolToolbarButton(
            symbols: symbols,
            accessibilityLabel: label,
            target: self,
            action: action
        )

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = label
        item.paletteLabel = label
        // The toolbar derives a default one from `label`; naming the action as
        // well means the overflow menu actually does something.
        let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        // Availability is ``apply(_:)``'s business, not the toolbar's.
        // Automatic validation of a view-based item only ever takes buttons
        // away, and the readouts must never go: the connection glyph is most
        // worth clicking when the connection is at its worst. Refresh is the
        // one item with an enabled state, and it is written from the readout.
        item.autovalidates = false

        // A newly built item shows whatever the readout said at construction,
        // so the next `apply(_:)` has to write every field rather than diff
        // against a state this button was never in.
        applied = nil

        return (item, button)
    }

    // MARK: Actions

    @objc private func refresh(_ sender: Any?) {
        actions.refresh()
    }

    @objc private func toggleKeepAwake(_ sender: Any?) {
        actions.toggleKeepAwake()
    }

    @objc private func openActivityLog(_ sender: Any?) {
        actions.openActivityLog()
    }

    @objc private func openConnectionInspector(_ sender: Any?) {
        actions.openConnectionInspector()
    }
}

private extension ConnectionStatus {
    /// Only `needsPasscode` differs from ``ConnectionStatus/systemImage``: a
    /// filled lock carries further in a toolbar than the outlined circle the
    /// inspector uses. The offline case used to be overridden too, with the
    /// identical glyph — so changing the status type's symbol left the toolbar
    /// showing the old one.
    var toolbarSymbol: String {
        if case .needsPasscode = self { return "lock.fill" }
        return systemImage
    }
}
