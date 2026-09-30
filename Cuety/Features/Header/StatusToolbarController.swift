#if os(macOS)
import AppKit
import SwiftUI

struct StatusToolbarReadout: Equatable {
    var keepsDisplayAwake: Bool
    var performanceMode: Bool
    var heartbeatSymbol: String
    var heartbeatTint: Color
    var heartbeatSummary: String
    var missedHeartbeats: Int
    var status: ConnectionStatus
    var isRefreshing: Bool
    var canRefresh: Bool
    var windowTitle: String
    var windowSubtitle: String
}

struct StatusToolbarActions {
    var toggleKeepAwake: () -> Void = {}
    var togglePerformanceMode: () -> Void = {}
    var openActivityLog: () -> Void = {}
    var openConnectionInspector: () -> Void = {}
    var refresh: () -> Void = {}
}

private extension NSToolbarItem.Identifier {
    static let cuetyRefresh = Self("org.arvadacenter.Cuety.toolbar.refresh")
    static let cuetyKeepAwake = Self("org.arvadacenter.Cuety.toolbar.keepAwake")
    static let cuetyPerformanceMode = Self("org.arvadacenter.Cuety.toolbar.performanceMode")
    static let cuetyActivityLog = Self("org.arvadacenter.Cuety.toolbar.activityLog")
    static let cuetyConnectionStatus = Self("org.arvadacenter.Cuety.toolbar.connectionStatus")
}

/// The main window's toolbar, built from stock `NSToolbarItem`s so every
/// button has AppKit's own press, glass, overflow and label behaviour. Only
/// an `NSSplitViewController` window gives the sidebar toggle its tracking
/// separator, which is why this is AppKit rather than a SwiftUI toolbar.
@MainActor
final class StatusToolbarController: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar

    var actions = StatusToolbarActions()

    private var applied: StatusToolbarReadout?
    private var pendingUpdate: Task<Void, Never>?
    private weak var window: NSWindow?

    private weak var refreshItem: NSToolbarItem?
    private weak var keepAwakeItem: NSToolbarItem?
    private weak var performanceModeItem: NSToolbarItem?
    private weak var activityLogItem: NSToolbarItem?
    private weak var statusItem: NSToolbarItem?

    override init() {
        toolbar = NSToolbar(identifier: "org.arvadacenter.Cuety.toolbar")
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func install(in window: NSWindow) {
        self.window = window
        guard window.toolbar !== toolbar else { return }
        window.toolbar = toolbar
    }

    /// SwiftUI updates the host view during its own layout pass; the window
    /// and toolbar are changed on the next turn instead.
    func scheduleUpdate(for view: NSView, readout: StatusToolbarReadout) {
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self, weak view] in
            guard !Task.isCancelled, let self, let view, let window = view.window else { return }
            install(in: window)
            apply(readout)
        }
    }

    func apply(_ readout: StatusToolbarReadout) {
        guard readout != applied else { return }
        applied = readout

        if let window {
            window.title = readout.windowTitle
            window.subtitle = readout.windowSubtitle
        }

        if let refreshItem {
            refreshItem.isEnabled = readout.canRefresh && !readout.isRefreshing
            refreshItem.toolTip = readout.isRefreshing
                ? "Searching for QLab workspaces…"
                : "Refresh Connections"
        }

        if let keepAwakeItem {
            let isOn = readout.keepsDisplayAwake
            keepAwakeItem.image = Self.symbol(isOn ? "sun.max.fill" : "sun.min")
            keepAwakeItem.style = isOn ? .prominent : .plain
            keepAwakeItem.toolTip = isOn
                ? "Keep Display Awake: on. The display will not sleep."
                : "Keep Display Awake: off. The display can sleep."
        }

        if let performanceModeItem {
            let isOn = readout.performanceMode
            performanceModeItem.image = Self.symbol(
                isOn ? "speedometer" : "gauge.with.dots.needle.33percent"
            )
            performanceModeItem.style = isOn ? .prominent : .plain
            performanceModeItem.toolTip = isOn
                ? "Performance Mode: on. Display animations and effects are reduced."
                : "Performance Mode: off."
        }

        if let activityLogItem {
            activityLogItem.image = Self.symbol(readout.heartbeatSymbol, tint: readout.heartbeatTint)
            activityLogItem.badge = readout.missedHeartbeats > 0 ? .count(readout.missedHeartbeats) : nil
            activityLogItem.toolTip = "Activity Log. \(readout.heartbeatSummary)"
        }

        if let statusItem {
            let status = readout.status
            statusItem.image = Self.symbol(status.toolbarSymbol, tint: status.tint)
            statusItem.toolTip = "\(status.title). \(status.detail)"
        }
    }

    private static let identifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .cuetyRefresh,
        .toggleSidebar,
        .sidebarTrackingSeparator,
        .cuetyKeepAwake,
        .space,
        .cuetyPerformanceMode,
        .space,
        .cuetyConnectionStatus,
        .cuetyActivityLog,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case .cuetyRefresh:
            item = makeItem(identifier, label: "Refresh Connections", symbol: "arrow.clockwise", action: #selector(refresh))
            if flag { refreshItem = item }
        case .cuetyKeepAwake:
            item = makeItem(identifier, label: "Keep Display Awake", symbol: "sun.min", action: #selector(toggleKeepAwake))
            if flag { keepAwakeItem = item }
        case .cuetyPerformanceMode:
            item = makeItem(
                identifier, label: "Performance Mode", symbol: "gauge.with.dots.needle.33percent",
                action: #selector(togglePerformanceMode)
            )
            if flag { performanceModeItem = item }
        case .cuetyActivityLog:
            item = makeItem(identifier, label: "Activity Log", symbol: "heart.slash.fill", action: #selector(openActivityLog))
            if flag { activityLogItem = item }
        case .cuetyConnectionStatus:
            item = makeItem(
                identifier, label: "Connection Status", symbol: ConnectionStatus.offline.toolbarSymbol,
                action: #selector(openConnectionInspector)
            )
            if flag { statusItem = item }
        default:
            return nil
        }
        // A new item shows the next readout, even if it has not changed.
        applied = nil
        return item
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = Self.symbol(symbol)
        item.isBordered = true
        item.target = self
        item.action = action
        // Enabled state follows the readout, not the responder chain.
        item.autovalidates = false
        return item
    }

    /// An SF Symbol, tinted when `tint` is given; otherwise a template image
    /// the toolbar colours itself.
    private static func symbol(_ name: String, tint: Color? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let tint else { return image }
        return image?.withSymbolConfiguration(.init(paletteColors: [NSColor(tint)]))
    }

    @objc private func refresh(_ sender: Any?) { actions.refresh() }
    @objc private func toggleKeepAwake(_ sender: Any?) { actions.toggleKeepAwake() }
    @objc private func togglePerformanceMode(_ sender: Any?) { actions.togglePerformanceMode() }
    @objc private func openActivityLog(_ sender: Any?) { actions.openActivityLog() }
    @objc private func openConnectionInspector(_ sender: Any?) { actions.openConnectionInspector() }
}

private extension ConnectionStatus {
    var toolbarSymbol: String {
        if case .needsPasscode = self { return "lock.fill" }
        return systemImage
    }
}
#endif
