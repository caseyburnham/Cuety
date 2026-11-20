import SwiftUI
import ShowControlCore

enum AppearanceMode: String, CaseIterable, Hashable, Sendable, Identifiable {
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

enum FontWeightChoice: String, CaseIterable, Hashable, Sendable, Identifiable {
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
}

/// How the detail pane presents the playhead: the big standby display with the
/// drawer beneath it, or the whole pane given over to the cue list.
enum CueLayout: String, CaseIterable, Hashable, Sendable, Identifiable {
    case display
    case list

    var id: String { rawValue }

    /// How many cues the cue list layout shows either side of the standby cue.
    static let listRowRadius = 4

    var title: String {
        switch self {
        case .display: "Display and Drawer"
        case .list: "Cue List"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "rectangle.bottomhalf.inset.filled"
        case .list: "text.line.first.and.arrowtriangle.forward"
        }
    }
}

enum PillSize: String, CaseIterable, Hashable, Sendable, Identifiable {
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

    var height: CGFloat {
        switch self {
        case .small: 28
        case .medium: 36
        case .large: 46
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

/// The color of the cue list layout's playhead arrow. Stored by raw value,
/// which for a cue color is QLab's own name for it.
enum PlayheadAccent: RawRepresentable, Hashable, Sendable, Identifiable {
    case systemBlue
    case standbyCue
    case cue(QLabCueColor)

    static let allCases: [Self] = [.systemBlue, .standbyCue] + QLabCueColor.allCases.map(Self.cue)

    init?(rawValue: String) {
        switch rawValue {
        case "systemBlue": self = .systemBlue
        case "standbyCue": self = .standbyCue
        default:
            guard let color = QLabCueColor(rawValue: rawValue) else { return nil }
            self = .cue(color)
        }
    }

    var rawValue: String {
        switch self {
        case .systemBlue: "systemBlue"
        case .standbyCue: "standbyCue"
        case .cue(let color): color.rawValue
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemBlue: "System"
        case .standbyCue: "Standby Cue"
        case .cue(let color): color.title
        }
    }

    func color(for standbyCue: Cue?) -> Color {
        switch self {
        case .systemBlue: .accentColor
        case .standbyCue: standbyCue?.color ?? .blue
        case .cue(let color): color.color
        }
    }
}

@Observable
final class Preferences {
    enum Limits {
        static let port = 1...65_535
        static let heartbeatInterval = 1.0...60.0
        static let requestTimeout = 1.0...60.0
        static let drawerRows = 1...10
    }

    let defaults: UserDefaults

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

    var playheadAccent: PlayheadAccent {
        didSet { defaults.set(playheadAccent.rawValue, forKey: Key.playheadAccent) }
    }

    var showsPlayhead: Bool {
        didSet { defaults.set(showsPlayhead, forKey: Key.showsPlayhead) }
    }

    var cueLayout: CueLayout {
        didSet { defaults.set(cueLayout.rawValue, forKey: Key.cueLayout) }
    }

    var showsDrawer: Bool {
        didSet { defaults.set(showsDrawer, forKey: Key.showsDrawer) }
    }

    /// How many rows the drawer shows either side of the playhead. The drawer's
    /// height follows from this, so it is set by dragging the drawer's handle
    /// rather than in Settings.
    var drawerRowCount: Int {
        didSet {
            let clamped = Limits.drawerRows.clamping(drawerRowCount)
            if drawerRowCount != clamped { drawerRowCount = clamped }
            defaults.set(drawerRowCount, forKey: Key.drawerRowCount)
        }
    }

    var showsDetailPills: Bool {
        didSet { defaults.set(showsDetailPills, forKey: Key.showsDetailPills) }
    }

    var enabledPills: Set<DetailPillKind> {
        didSet { defaults.set(enabledPills.map(\.rawValue), forKey: Key.enabledPills) }
    }

    var pillSize: PillSize {
        didSet { defaults.set(pillSize.rawValue, forKey: Key.pillSize) }
    }

    var showsCueTypeLabel: Bool {
        didSet { defaults.set(showsCueTypeLabel, forKey: Key.showsCueTypeLabel) }
    }

    var visiblePills: [DetailPillKind] {
        guard showsDetailPills else { return [] }
        return DetailPillKind.allCases.filter { enabledPills.contains($0) || $0.isAlwaysVisible }
    }

    var showsMenuBarExtra: Bool {
        didSet { defaults.set(showsMenuBarExtra, forKey: Key.showsMenuBarExtra) }
    }

    var menuBarReadout: MenuBarReadout {
        didSet { defaults.set(menuBarReadout.rawValue, forKey: Key.menuBarReadout) }
    }

    var keepsDisplayAwake: Bool {
        didSet { defaults.set(keepsDisplayAwake, forKey: Key.keepsDisplayAwake) }
    }

    var performanceMode: Bool {
        didSet { defaults.set(performanceMode, forKey: Key.performanceMode) }
    }

    var defaultPort: Int {
        didSet {
            let clamped = Limits.port.clamping(defaultPort)
            if defaultPort != clamped { defaultPort = clamped }
            defaults.set(defaultPort, forKey: Key.defaultPort)
        }
    }

    var heartbeatInterval: TimeInterval {
        didSet {
            let clamped = Limits.heartbeatInterval.clamping(heartbeatInterval)
            if heartbeatInterval != clamped { heartbeatInterval = clamped }
            defaults.set(heartbeatInterval, forKey: Key.heartbeatInterval)
        }
    }

    var requestTimeout: TimeInterval {
        didSet {
            let clamped = Limits.requestTimeout.clamping(requestTimeout)
            if requestTimeout != clamped { requestTimeout = clamped }
            defaults.set(requestTimeout, forKey: Key.requestTimeout)
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
        defaults.register(defaults: [
            Key.usesRoundedSystemFont: true,
            Key.showsCueName: true,
            Key.showsPlayhead: true,
            Key.showsDrawer: true,
            Key.drawerRowCount: 3,
            Key.showsDetailPills: true,
            Key.showsCueTypeLabel: true,
            Key.defaultPort: ShowControlDefaults.qlabTCPPort,
            Key.heartbeatInterval: 5.0,
            Key.requestTimeout: 5.0,
        ])

        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .automatic
        usesRoundedSystemFont = defaults.bool(forKey: Key.usesRoundedSystemFont)
        fontWeight = defaults.string(forKey: Key.fontWeight)
            .flatMap(FontWeightChoice.init(rawValue:)) ?? .bold
        showsCueName = defaults.bool(forKey: Key.showsCueName)
        playheadAccent = defaults.string(forKey: Key.playheadAccent)
            .flatMap(PlayheadAccent.init(rawValue:)) ?? .systemBlue
        showsPlayhead = defaults.bool(forKey: Key.showsPlayhead)
        cueLayout = defaults.string(forKey: Key.cueLayout)
            .flatMap(CueLayout.init(rawValue:)) ?? .display
        showsDrawer = defaults.bool(forKey: Key.showsDrawer)
        drawerRowCount = Limits.drawerRows.clamping(defaults.integer(forKey: Key.drawerRowCount))

        showsDetailPills = defaults.bool(forKey: Key.showsDetailPills)
        enabledPills = Self.loadEnabledPills(from: defaults)
        pillSize = defaults.string(forKey: Key.pillSize)
            .flatMap(PillSize.init(rawValue:)) ?? .default
        showsCueTypeLabel = defaults.bool(forKey: Key.showsCueTypeLabel)

        showsMenuBarExtra = defaults.bool(forKey: Key.showsMenuBarExtra)
        menuBarReadout = defaults.string(forKey: Key.menuBarReadout)
            .flatMap(MenuBarReadout.init(rawValue:)) ?? .default
        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)
        performanceMode = defaults.bool(forKey: Key.performanceMode)

        defaultPort = Limits.port.clamping(defaults.integer(forKey: Key.defaultPort))
        heartbeatInterval = Limits.heartbeatInterval.clamping(defaults.double(forKey: Key.heartbeatInterval))
        requestTimeout = Limits.requestTimeout.clamping(defaults.double(forKey: Key.requestTimeout))
        autoConnect = defaults.bool(forKey: Key.autoConnect)

        if let serverID = defaults.string(forKey: Key.lastServerID),
           let workspaceID = defaults.string(forKey: Key.lastWorkspaceID) {
            lastWorkspace = WorkspaceSelection(
                serverID: serverID, workspaceID: workspaceID
            )
        }
    }

    private static func loadEnabledPills(from defaults: UserDefaults) -> Set<DetailPillKind> {
        guard let stored = defaults.array(forKey: Key.enabledPills) as? [String] else {
            return DetailPillKind.defaultEnabled
        }

        return Set(stored.compactMap(DetailPillKind.init(rawValue:)))
    }

    private enum Key {
        static let appearance = "appearance"
        static let usesRoundedSystemFont = "usesRoundedSystemFont"
        static let fontWeight = "fontWeight"
        static let showsCueName = "showsCueName"
        static let playheadAccent = "playheadAccent"
        static let showsPlayhead = "showsPlayhead"
        static let cueLayout = "cueLayout"
        static let showsDrawer = "showsDrawer"
        static let drawerRowCount = "drawerRowCount"
        static let showsDetailPills = "showsDetailPills"
        static let enabledPills = "enabledPills"
        static let pillSize = "pillSize"
        static let showsCueTypeLabel = "showsCueTypeLabel"
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let menuBarReadout = "menuBarReadout"
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
