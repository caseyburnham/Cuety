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
}

/// What the toolbar's buttons do.
///
/// Closures rather than a reference to the model, because two of them are
/// `openWindow` calls and that only exists in the SwiftUI environment.
struct StatusToolbarActions {
    var toggleKeepAwake: () -> Void = {}
    var openActivityLog: () -> Void = {}
    var openConnectionInspector: () -> Void = {}
}

private extension NSToolbarItem.Identifier {
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
        guard window.toolbar !== toolbar else { return }
        window.toolbar = toolbar
    }

    // MARK: Updating

    /// Matches the buttons to `readout`.
    func apply(_ readout: StatusToolbarReadout) {
        // Only the effects that run off a *change* are gated here. The glyph
        // transitions handle Reduce Motion themselves, inside ``ToolbarGlyph``.
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previous = applied
        applied = readout

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

    /// The sidebar control, then the title, then the status cluster at the
    /// trailing edge — the standard composition for a window with a sidebar.
    /// The fixed space keeps the keep-awake toggle from reading as a third
    /// status glyph.
    ///
    /// The first two are the system's own items, not Cuety's. `.toggleSidebar`
    /// sends `toggleSidebar:` down the responder chain, where the
    /// `NSSplitViewController` behind `NavigationSplitView` answers it, and
    /// `columnVisibility` writes the result back to
    /// ``AppModel/sidebarVisibility`` — so the model still hears about it
    /// without Cuety owning the control. Being the *standard* item is also
    /// what lets AppKit place it against the sidebar's edge and move it with
    /// the divider; a custom item in the same slot is just an item that
    /// happens to be first.
    ///
    /// The sidebar toggle goes *after* the separator, not before it. Items
    /// ahead of a tracking separator are laid out inside the sidebar's own
    /// width, so putting it first pinned it to the far left and — once the
    /// sidebar collapsed and that region went to zero — left it nowhere to fit,
    /// at which point AppKit moved it into the overflow chevron at the far
    /// right and re-laid-out every other item to do it. Behind the separator it
    /// sits at the leading edge of the detail pane and travels with the
    /// divider, which is where Mail and Notes keep theirs.
    private static let identifiers: [NSToolbarItem.Identifier] = [
        .sidebarTrackingSeparator,
        .toggleSidebar,
        .flexibleSpace,
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
            // The sidebar toggle, the tracking separator and the spacers. The
            // toolbar builds all of those itself, which is the point of using
            // their identifiers rather than items of Cuety's own.
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
        // Nothing here is ever disabled — the connection glyph is most worth
        // clicking when the connection is at its worst — and automatic
        // validation of a view-based item only ever takes buttons away.
        item.autovalidates = false

        // A newly built item shows whatever the readout said at construction,
        // so the next `apply(_:)` has to write every field rather than diff
        // against a state this button was never in.
        applied = nil

        return (item, button)
    }

    // MARK: Actions

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
