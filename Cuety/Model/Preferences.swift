import SwiftUI
import ShowControlCore
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

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

    var platformWeight: PlatformFont.Weight {
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
enum CueLayout: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case display
    case list

    var id: String { rawValue }

    /// How many cues the cue list layout shows either side of the standby cue.
    static let listRowRadius = 2

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

/// How the standby display sizes the cue number.
enum CueNumberSizing: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// Sized to fit the widest number in the cue list, so every cue in the
    /// list is drawn at the same size.
    case fixed
    /// A point size the user chooses, shrunk only when it would not fit.
    case custom
    /// Each number as large as it can be drawn in the space available.
    case dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: "Fixed"
        case .custom: "Custom"
        case .dynamic: "As Large as Possible"
        }
    }
}

enum PlayheadAccent: String, Codable, Hashable, Sendable, Identifiable {
    case systemBlue
    case standbyCue
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case magenta
    case crimson
    case peach
    case olive
    case forest
    case skyBlue = "sky blue"
    case midnight
    case indigo
    case lavender
    case plum
    case berry
    case hotPink = "hot pink"
    case gray

    static let allCases: [Self] = [.systemBlue, .standbyCue] + QLabCueColor.allCases.compactMap {
        Self(rawValue: $0.rawValue)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemBlue: "System Blue"
        case .standbyCue: "Standby Cue"
        default: QLabCueColor(rawValue: rawValue)?.title ?? rawValue
        }
    }

    func color(for standbyCue: Cue?) -> Color {
        switch self {
        case .systemBlue:
            .blue
        case .standbyCue:
            standbyCue?.color ?? .blue
        default:
            QLabCueColor(rawValue: rawValue)?.color ?? .blue
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
        static let cueNumberSize = 24.0...Double(Typography.cueNumberBaseSize)
    }

    let defaults: UserDefaults


    private var storedDrawerRowCount: Int
    private var storedDefaultPort: Int
    private var storedHeartbeatInterval: TimeInterval
    private var storedRequestTimeout: TimeInterval
    private var storedCustomCueNumberSize: Double


    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var usesRoundedSystemFont: Bool {
        didSet { defaults.set(usesRoundedSystemFont, forKey: Key.usesRoundedSystemFont) }
    }

    var fontWeight: FontWeightChoice {
        didSet { defaults.set(fontWeight.rawValue, forKey: Key.fontWeight) }
    }

    var cueNumberSizing: CueNumberSizing {
        didSet { defaults.set(cueNumberSizing.rawValue, forKey: Key.cueNumberSizing) }
    }

    /// The point size used when `cueNumberSizing` is `.custom`.
    var customCueNumberSize: Double {
        get { storedCustomCueNumberSize }
        set {
            storedCustomCueNumberSize = Limits.cueNumberSize.clamping(newValue)
            defaults.set(storedCustomCueNumberSize, forKey: Key.customCueNumberSize)
        }
    }


    var showsCueName: Bool {
        didSet { defaults.set(showsCueName, forKey: Key.showsCueName) }
    }

    var playheadAccent: PlayheadAccent {
        didSet { defaults.set(playheadAccent.rawValue, forKey: Key.playheadAccent) }
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
        get { storedDrawerRowCount }
        set {
            storedDrawerRowCount = Limits.drawerRows.clamping(newValue)
            defaults.set(storedDrawerRowCount, forKey: Key.drawerRowCount)
        }
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
        DetailPillKind.defaultOrder.filter { enabledPills.contains($0) || $0.isAlwaysVisible }
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
        usesRoundedSystemFont = defaults.object(forKey: Key.usesRoundedSystemFont) as? Bool ?? true
        fontWeight = defaults.string(forKey: Key.fontWeight)
            .flatMap(FontWeightChoice.init(rawValue:)) ?? .bold
        cueNumberSizing = defaults.string(forKey: Key.cueNumberSizing)
            .flatMap(CueNumberSizing.init(rawValue:)) ?? .fixed
        storedCustomCueNumberSize = Limits.cueNumberSize.clamping(
            defaults.object(forKey: Key.customCueNumberSize) as? Double ?? 240
        )

        showsCueName = defaults.object(forKey: Key.showsCueName) as? Bool ?? true
        playheadAccent = defaults.string(forKey: Key.playheadAccent)
            .flatMap(PlayheadAccent.init(rawValue:)) ?? .systemBlue
        cueLayout = defaults.string(forKey: Key.cueLayout)
            .flatMap(CueLayout.init(rawValue:)) ?? .display
        showsDrawer = defaults.object(forKey: Key.showsDrawer) as? Bool ?? true
        storedDrawerRowCount = Limits.drawerRows.clamping(
            defaults.object(forKey: Key.drawerRowCount) as? Int ?? 3
        )

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
            defaults.object(forKey: Key.defaultPort) as? Int ?? ShowControlDefaults.qlabTCPPort
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


    private static func loadEnabledPills(from defaults: UserDefaults) -> Set<DetailPillKind> {
        guard let stored = defaults.array(forKey: Key.enabledPills) as? [String] else {
            return DetailPillKind.defaultEnabled
        }

        return Set(stored.compactMap(DetailPillKind.init(rawValue:)))
    }

    private func persistEnabledPills() {
        defaults.set(enabledPills.map(\.rawValue), forKey: Key.enabledPills)
    }


    private enum Key {
        static let appearance = "appearance"
        static let usesRoundedSystemFont = "usesRoundedSystemFont"
        static let fontWeight = "fontWeight"
        static let cueNumberSizing = "cueNumberSizing"
        static let customCueNumberSize = "customCueNumberSize"
        static let showsCueName = "showsCueName"
        static let playheadAccent = "playheadAccent"
        static let cueLayout = "cueLayout"
        static let showsDrawer = "showsDrawer"
        static let drawerRowCount = "drawerRowCount"
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
