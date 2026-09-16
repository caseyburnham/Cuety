import SwiftUI

enum AppearanceMode: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum FontWeightChoice: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        case .black: "Black"
        }
    }

    var weight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    var appKitWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

enum PillSize: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    static let `default` = PillSize.medium

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var font: Font {
        switch self {
        case .small: .footnote
        case .medium: .callout
        case .large: .title3
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 9
        case .medium: 12
        case .large: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: 5
        case .medium: 7
        case .large: 10
        }
    }

    var spacing: CGFloat {
        switch self {
        case .small: 8
        case .medium: 10
        case .large: 14
        }
    }

    var glassSpacing: CGFloat { spacing + 4 }
}

@Observable
final class Preferences {
    enum Limits {
        static let port = 1...65_535
        static let heartbeatInterval = 1.0...60.0
        static let requestTimeout = 1.0...60.0
        static let drawerRows = 0...10
    }

    let defaults: UserDefaults


    private var storedDrawerRowsAbove: Int
    private var storedDrawerRowsBelow: Int
    private var storedDefaultPort: Int
    private var storedHeartbeatInterval: TimeInterval
    private var storedRequestTimeout: TimeInterval


    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var usesRoundedSystemFont: Bool {
        didSet { defaults.set(usesRoundedSystemFont, forKey: Key.usesRoundedSystemFont) }
    }

    var fontWeight: FontWeightChoice {
        didSet { defaults.set(fontWeight.rawValue, forKey: Key.fontWeight) }
    }


    var showsCueName: Bool {
        didSet { defaults.set(showsCueName, forKey: Key.showsCueName) }
    }

    var showsDrawer: Bool {
        didSet { defaults.set(showsDrawer, forKey: Key.showsDrawer) }
    }

    var drawerRowsAboveCount: Int {
        get { storedDrawerRowsAbove }
        set {
            storedDrawerRowsAbove = Limits.drawerRows.clamping(newValue)
            defaults.set(storedDrawerRowsAbove, forKey: Key.drawerRowsAboveCount)
        }
    }

    var drawerRowsBelowCount: Int {
        get { storedDrawerRowsBelow }
        set {
            storedDrawerRowsBelow = Limits.drawerRows.clamping(newValue)
            defaults.set(storedDrawerRowsBelow, forKey: Key.drawerRowsBelowCount)
        }
    }


    var pillOrder: [DetailPillKind] {
        didSet { persistPillOrder() }
    }

    var enabledPills: Set<DetailPillKind> {
        didSet { persistEnabledPills() }
    }

    var pillSize: PillSize {
        didSet { defaults.set(pillSize.rawValue, forKey: Key.pillSize) }
    }

    var showsCueTypeLabel: Bool {
        didSet { defaults.set(showsCueTypeLabel, forKey: Key.showsCueTypeLabel) }
    }

    var visiblePills: [DetailPillKind] {
        pillOrder.filter(enabledPills.contains)
    }


    var showsMenuBarExtra: Bool {
        didSet { defaults.set(showsMenuBarExtra, forKey: Key.showsMenuBarExtra) }
    }

    var menuBarReadout: MenuBarReadout {
        didSet { defaults.set(menuBarReadout.rawValue, forKey: Key.menuBarReadout) }
    }

    var showsDockBadge: Bool {
        didSet { defaults.set(showsDockBadge, forKey: Key.showsDockBadge) }
    }


    var keepsDisplayAwake: Bool {
        didSet { defaults.set(keepsDisplayAwake, forKey: Key.keepsDisplayAwake) }
    }

    var performanceMode: Bool {
        didSet { defaults.set(performanceMode, forKey: Key.performanceMode) }
    }


    var defaultPort: Int {
        get { storedDefaultPort }
        set {
            storedDefaultPort = Limits.port.clamping(newValue)
            defaults.set(storedDefaultPort, forKey: Key.defaultPort)
        }
    }

    var heartbeatInterval: TimeInterval {
        get { storedHeartbeatInterval }
        set {
            storedHeartbeatInterval = Limits.heartbeatInterval.clamping(newValue)
            defaults.set(storedHeartbeatInterval, forKey: Key.heartbeatInterval)
        }
    }

    var requestTimeout: TimeInterval {
        get { storedRequestTimeout }
        set {
            storedRequestTimeout = Limits.requestTimeout.clamping(newValue)
            defaults.set(storedRequestTimeout, forKey: Key.requestTimeout)
        }
    }

    var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }

    var lastWorkspace: WorkspaceSelection? {
        didSet {
            defaults.set(lastWorkspace?.serverID, forKey: Key.lastServerID)
            defaults.set(lastWorkspace?.workspaceID, forKey: Key.lastWorkspaceID)
        }
    }


    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .automatic
        usesRoundedSystemFont = defaults.bool(forKey: Key.usesRoundedSystemFont)
        fontWeight = defaults.string(forKey: Key.fontWeight)
            .flatMap(FontWeightChoice.init(rawValue:)) ?? .bold

        showsCueName = defaults.object(forKey: Key.showsCueName) as? Bool ?? true
        showsDrawer = defaults.object(forKey: Key.showsDrawer) as? Bool ?? true
        storedDrawerRowsAbove = Limits.drawerRows.clamping(
            defaults.object(forKey: Key.drawerRowsAboveCount) as? Int ?? 3
        )
        storedDrawerRowsBelow = Limits.drawerRows.clamping(
            defaults.object(forKey: Key.drawerRowsBelowCount) as? Int ?? 3
        )

        pillOrder = Self.loadPillOrder(from: defaults)
        enabledPills = Self.loadEnabledPills(from: defaults)
        pillSize = defaults.string(forKey: Key.pillSize)
            .flatMap(PillSize.init(rawValue:)) ?? .default
        showsCueTypeLabel = defaults.object(forKey: Key.showsCueTypeLabel) as? Bool ?? true

        showsMenuBarExtra = defaults.bool(forKey: Key.showsMenuBarExtra)
        menuBarReadout = defaults.string(forKey: Key.menuBarReadout)
            .flatMap(MenuBarReadout.init(rawValue:)) ?? .default
        showsDockBadge = defaults.bool(forKey: Key.showsDockBadge)

        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)
        performanceMode = defaults.bool(forKey: Key.performanceMode)

        storedDefaultPort = Limits.port.clamping(
            defaults.object(forKey: Key.defaultPort) as? Int ?? 53000
        )
        storedHeartbeatInterval = Limits.heartbeatInterval.clamping(
            defaults.object(forKey: Key.heartbeatInterval) as? TimeInterval ?? 5
        )
        storedRequestTimeout = Limits.requestTimeout.clamping(
            defaults.object(forKey: Key.requestTimeout) as? TimeInterval ?? 5
        )
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? false

        if let serverID = defaults.string(forKey: Key.lastServerID),
           let workspaceID = defaults.string(forKey: Key.lastWorkspaceID) {
            lastWorkspace = WorkspaceSelection(
                serverID: serverID, workspaceID: workspaceID
            )
        }
    }


    private static func loadPillOrder(from defaults: UserDefaults) -> [DetailPillKind] {
        let stored = (defaults.array(forKey: Key.pillOrder) as? [String] ?? [])
            .compactMap(DetailPillKind.init(rawValue:))
        let missing = DetailPillKind.defaultOrder.filter { !stored.contains($0) }
        return stored.isEmpty ? DetailPillKind.defaultOrder : stored + missing
    }

    private static func loadEnabledPills(from defaults: UserDefaults) -> Set<DetailPillKind> {
        guard let stored = defaults.array(forKey: Key.enabledPills) as? [String] else {
            return DetailPillKind.defaultEnabled
        }
        return Set(stored.compactMap(DetailPillKind.init(rawValue:)))
    }

    private func persistPillOrder() {
        defaults.set(pillOrder.map(\.rawValue), forKey: Key.pillOrder)
    }

    private func persistEnabledPills() {
        defaults.set(enabledPills.map(\.rawValue), forKey: Key.enabledPills)
    }


    private enum Key {
        static let appearance = "appearance"
        static let usesRoundedSystemFont = "usesRoundedSystemFont"
        static let fontWeight = "fontWeight"
        static let showsCueName = "showsCueName"
        static let showsDrawer = "showsDrawer"
        static let drawerRowsAboveCount = "drawerPreviousCount"
        static let drawerRowsBelowCount = "drawerUpcomingCount"
        static let pillOrder = "pillOrder"
        static let enabledPills = "enabledPills"
        static let pillSize = "pillSize"
        static let showsCueTypeLabel = "showsCueTypeLabel"
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let menuBarReadout = "menuBarReadout"
        static let showsDockBadge = "showsDockBadge"
        static let keepsDisplayAwake = "keepsDisplayAwake"
        static let performanceMode = "performanceMode"
        static let defaultPort = "defaultPort"
        static let heartbeatInterval = "heartbeatInterval"
        static let requestTimeout = "requestTimeout"
        static let autoConnect = "autoConnect"
        static let lastServerID = "lastServerID"
        static let lastWorkspaceID = "lastWorkspaceID"
    }
}

extension ClosedRange {
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
