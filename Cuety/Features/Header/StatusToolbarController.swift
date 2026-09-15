import AppKit
import SwiftUI

struct StatusToolbarReadout: Equatable {
    var keepsDisplayAwake: Bool
    var heartbeatSymbol: String
    var heartbeatTint: Color
    var heartbeatCount: Int
    var heartbeatSummary: String
    var status: ConnectionStatus
    var isRefreshing: Bool
    var canRefresh: Bool
    var windowTitle: String
    var windowSubtitle: String
}

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

@MainActor
final class StatusToolbarController: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar

    var actions = StatusToolbarActions()

    private var applied: StatusToolbarReadout?
    private var pendingUpdate: Task<Void, Never>?

    private weak var refreshButton: SymbolToolbarButton?
    private weak var keepAwakeButton: SymbolToolbarButton?
    private weak var heartbeatButton: SymbolToolbarButton?
    private weak var statusButton: SymbolToolbarButton?

    override init() {
        toolbar = NSToolbar(identifier: "com.ivxx.Cuety.toolbar")
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

    private weak var window: NSWindow?

    func scheduleUpdate(for view: NSView, readout: StatusToolbarReadout) {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor [weak self, weak view] in
            guard let self, let view, let window = view.window else { return }
            self.install(in: window)
            self.apply(readout)
        }
    }

    func apply(_ readout: StatusToolbarReadout) {
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
            if previous?.canRefresh != readout.canRefresh {
                refreshButton.isEnabled = readout.canRefresh
            }
        }

        if let keepAwakeButton, previous?.keepsDisplayAwake != readout.keepsDisplayAwake {
            let isOn = readout.keepsDisplayAwake
            keepAwakeButton.state = isOn ? .on : .off
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
            if previous?.heartbeatTint != readout.heartbeatTint {
                heartbeatButton.glyphTint = readout.heartbeatTint
            }

            heartbeatButton.setSymbol(readout.heartbeatSymbol)

            if previous?.heartbeatSummary != readout.heartbeatSummary {
                heartbeatButton.toolTip = "Activity Log. " + readout.heartbeatSummary
                heartbeatButton.setAccessibilityValue(readout.heartbeatSummary)
            }

            if animates, let previous, previous.heartbeatCount != readout.heartbeatCount {
                heartbeatButton.bounce()
            }
        }

        if let statusButton, previous?.status != readout.status {
            let status = readout.status
            statusButton.glyphTint = status.tint
            statusButton.setSymbol(status.toolbarSymbol)
            statusButton.setWorking(animates && status.isTransitional)
            statusButton.toolTip = "\(status.title). \(status.detail)"
            statusButton.setAccessibilityValue(status.title)
        }
    }

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
        let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        item.autovalidates = false

        applied = nil

        return (item, button)
    }

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
    var toolbarSymbol: String {
        if case .needsPasscode = self { return "lock.fill" }
        return systemImage
    }
}
