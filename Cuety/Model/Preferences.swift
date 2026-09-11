import SwiftUI

/// The user's chosen appearance for the app, independent of the system setting.
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

    /// `nil` means "follow the system", which is what `preferredColorScheme` wants.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Every user-facing setting, persisted to `UserDefaults`.
///
/// One observable object rather than scattered `@AppStorage` properties, so
/// that the networking layer can read connection settings without pulling in
/// SwiftUI, and so defaults live in exactly one place.
@Observable
final class Preferences {
    /// The store these preferences persist to.
    ///
    /// Readable so that everything belonging to one ``AppModel`` shares one
    /// store. ``QLabBrowser`` persists the manual server list, and it used to
    /// reach for `.standard` on its own — so a test injecting an isolated
    /// suite isolated the preferences and nothing else, and wrote real manual
    /// servers into the real app's sidebar. It did exactly that.
    let defaults: UserDefaults

    // MARK: Appearance and typography

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// A font family name from ``FontCatalog``, or `nil` for the system font.
    ///
    /// The system font is the default deliberately: it has the best numeric
    /// figures and the widest weight range of anything guaranteed installed.
    var fontFamily: String? {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    var usesRoundedSystemFont: Bool {
        didSet { defaults.set(usesRoundedSystemFont, forKey: Key.usesRoundedSystemFont) }
    }

    // MARK: Display

    var showsCueName: Bool {
        didSet { defaults.set(showsCueName, forKey: Key.showsCueName) }
    }

    var showsDrawer: Bool {
        didSet { defaults.set(showsDrawer, forKey: Key.showsDrawer) }
    }

    /// How many rows of the cue list the drawer shows above the playhead.
    ///
    /// Rows, in two senses, neither of which is "cues". The drawer cannot know
    /// which cues have been *taken*, so this counts positions rather than
    /// history — the old name, "already-taken cues", described something Cuety
    /// has no way to establish. And a group is a single row however many cues
    /// are inside it, so three rows is three lines on screen rather than three
    /// cues. The persisted key keeps its old spelling so an existing setting
    /// is not silently reset.
    var drawerRowsAboveCount: Int {
        didSet { defaults.set(drawerRowsAboveCount, forKey: Key.drawerRowsAboveCount) }
    }

    /// How many rows of the cue list the drawer shows below the playhead.
    var drawerRowsBelowCount: Int {
        didSet { defaults.set(drawerRowsBelowCount, forKey: Key.drawerRowsBelowCount) }
    }

    // MARK: Detail pills

    /// Every pill in display order, including disabled ones — reordering in
    /// Settings must not be lost just because a pill is currently switched off.
    var pillOrder: [DetailPillKind] {
        didSet { persistPillOrder() }
    }

    var enabledPills: Set<DetailPillKind> {
        didSet { persistEnabledPills() }
    }

    /// The pills to actually render, in the user's order.
    var visiblePills: [DetailPillKind] {
        pillOrder.filter(enabledPills.contains)
    }

    // MARK: System

    var keepsDisplayAwake: Bool {
        didSet { defaults.set(keepsDisplayAwake, forKey: Key.keepsDisplayAwake) }
    }

    // MARK: Connection

    var defaultPort: Int {
        didSet { defaults.set(defaultPort, forKey: Key.defaultPort) }
    }

    /// Seconds between `/thump` messages.
    var heartbeatInterval: TimeInterval {
        didSet { defaults.set(heartbeatInterval, forKey: Key.heartbeatInterval) }
    }

    /// Seconds before an unanswered request fails.
    var requestTimeout: TimeInterval {
        didSet { defaults.set(requestTimeout, forKey: Key.requestTimeout) }
    }

    /// Reconnect to the last-used workspace automatically at launch.
    ///
    /// Off by default: Cuety opens a socket to a show control machine, which is
    /// the operator's call to make, not something to do before they've asked.
    var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }

    /// The workspace ``autoConnect`` should restore, recorded on every
    /// successful connection.
    ///
    /// Persisted as two plain strings rather than an encoded struct: a
    /// half-written or stale value then degrades to "no last workspace" instead
    /// of a decode failure, and the keys stay readable in `defaults(1)`.
    var lastWorkspace: WorkspaceSelection? {
        didSet {
            defaults.set(lastWorkspace?.serverID, forKey: Key.lastServerID)
            defaults.set(lastWorkspace?.workspaceID, forKey: Key.lastWorkspaceID)
        }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .automatic
        fontFamily = defaults.string(forKey: Key.fontFamily)
        usesRoundedSystemFont = defaults.bool(forKey: Key.usesRoundedSystemFont)

        showsCueName = defaults.object(forKey: Key.showsCueName) as? Bool ?? true
        showsDrawer = defaults.object(forKey: Key.showsDrawer) as? Bool ?? true
        drawerRowsAboveCount = defaults.object(forKey: Key.drawerRowsAboveCount) as? Int ?? 3
        drawerRowsBelowCount = defaults.object(forKey: Key.drawerRowsBelowCount) as? Int ?? 3

        pillOrder = Self.loadPillOrder(from: defaults)
        enabledPills = Self.loadEnabledPills(from: defaults)

        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)

        defaultPort = defaults.object(forKey: Key.defaultPort) as? Int ?? 53000
        heartbeatInterval = defaults.object(forKey: Key.heartbeatInterval) as? TimeInterval ?? 5
        requestTimeout = defaults.object(forKey: Key.requestTimeout) as? TimeInterval ?? 5
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? false

        if let serverID = defaults.string(forKey: Key.lastServerID),
           let workspaceID = defaults.string(forKey: Key.lastWorkspaceID) {
            lastWorkspace = WorkspaceSelection(
                serverID: serverID, workspaceID: workspaceID
            )
        }
    }

    // MARK: - Pill persistence

    private static func loadPillOrder(from defaults: UserDefaults) -> [DetailPillKind] {
        let stored = (defaults.array(forKey: Key.pillOrder) as? [String] ?? [])
            .compactMap(DetailPillKind.init(rawValue:))
        // Union with the canonical order so a pill added in a later version of
        // Cuety still appears for someone upgrading, rather than silently
        // vanishing because it wasn't in their saved list.
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

    // MARK: - Keys

    private enum Key {
        static let appearance = "appearance"
        static let fontFamily = "fontFamily"
        static let usesRoundedSystemFont = "usesRoundedSystemFont"
        static let showsCueName = "showsCueName"
        static let showsDrawer = "showsDrawer"
        // Spelled as they were first persisted. Renaming the properties above
        // must not reset a setting the operator already chose.
        static let drawerRowsAboveCount = "drawerPreviousCount"
        static let drawerRowsBelowCount = "drawerUpcomingCount"
        static let pillOrder = "pillOrder"
        static let enabledPills = "enabledPills"
        static let keepsDisplayAwake = "keepsDisplayAwake"
        static let defaultPort = "defaultPort"
        static let heartbeatInterval = "heartbeatInterval"
        static let requestTimeout = "requestTimeout"
        static let autoConnect = "autoConnect"
        static let lastServerID = "lastServerID"
        static let lastWorkspaceID = "lastWorkspaceID"
    }
}
