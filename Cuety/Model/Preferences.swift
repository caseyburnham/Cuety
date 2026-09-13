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

/// The weights offered for the cue number.
///
/// A fixed list rather than every weight `Font.Weight` defines: `ultraLight`
/// through `light` are unreadable at a distance, which is the one thing the
/// cue display exists to be. The system font has all six of these, and a
/// custom family that lacks one gets the nearest face the font machinery can
/// synthesise — the same fallback `Font/weight(_:)` applies anywhere.
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
}

/// How large the detail pills beneath the cue name are drawn.
///
/// Three steps rather than a continuous slider: the pills exist to be read at
/// a glance from wherever the operator sits, and the useful question is
/// "bigger or smaller than this", not "how many points".
///
/// The text sizes are `Font` text styles rather than fixed point sizes, so the
/// pills still follow the system text size the way everything else does.
enum PillSize: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// The size the pills were drawn at before this was a choice, and so the
    /// one Reset returns to.
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

    /// The gap between pills, and between the inline row and the note beneath
    /// it. Scales with the pills so that large ones do not end up crowded.
    var spacing: CGFloat {
        switch self {
        case .small: 8
        case .medium: 10
        case .large: 14
        }
    }

    /// The radius over which neighbouring pills blend into one another. Kept
    /// a little wider than ``spacing``, which is what lets pills that sit side
    /// by side merge as they appear and disappear.
    var glassSpacing: CGFloat { spacing + 4 }
}

/// Every user-facing setting, persisted to `UserDefaults`.
///
/// One observable object rather than scattered `@AppStorage` properties, so
/// that the networking layer can read connection settings without pulling in
/// SwiftUI, and so defaults live in exactly one place.
@Observable
final class Preferences {
    /// The range every numeric setting is held to.
    ///
    /// One definition per setting, used by the loader, by the property that
    /// stores it, *and* by the Settings control that offers it — so a control's
    /// bounds cannot drift from what the app will actually accept. They had
    /// already drifted: the steppers promised 1...60 and 0...10 while the
    /// loader accepted whatever was in `UserDefaults`, so a value written by an
    /// earlier build, by `defaults write`, or by a synced preference file went
    /// straight through. A `requestTimeout` of 0 fails every request
    /// immediately, and a `heartbeatInterval` of 0 turns the heartbeat into a
    /// tight loop aimed at a show control machine.
    enum Limits {
        /// Excludes 0 and everything above `UInt16`, which are the values a
        /// port cannot be. The Add Server sheet disables Add for anything
        /// outside this range, so an out-of-range default port presented the
        /// operator with a pre-filled field and a dead button.
        static let port = 1...65_535
        static let heartbeatInterval = 1.0...60.0
        static let requestTimeout = 1.0...60.0
        /// Zero is meaningful — an operator may want only the rows below the
        /// playhead — so the floor is 0 rather than 1.
        static let drawerRows = 0...10
    }

    /// The store these preferences persist to.
    ///
    /// Readable so that everything belonging to one ``AppModel`` shares one
    /// store. ``QLabBrowser`` persists the manual server list, and it used to
    /// reach for `.standard` on its own — so a test injecting an isolated
    /// suite isolated the preferences and nothing else, and wrote real manual
    /// servers into the real app's sidebar. It did exactly that.
    let defaults: UserDefaults

    // MARK: Clamped storage

    // Every setting with a range in ``Limits`` is a computed property over one
    // of these, rather than a stored property with a `didSet` that clamps
    // itself.
    //
    // `didSet` looks like the obvious home for a clamp, and outside
    // `@Observable` it would be: assigning to a plain stored property inside
    // its own `didSet` does not re-enter the observer. But the macro rewrites
    // each stored property into a computed one over hidden storage, and the
    // `didSet` rides on that storage — so the self-assignment goes back in
    // through the setter and recurses until the stack is gone. The app took
    // the first Stepper click and died.
    //
    // Clamping in the setter instead terminates by construction: nothing
    // assigns to the property being set.
    private var storedDrawerRowsAbove: Int
    private var storedDrawerRowsBelow: Int
    private var storedDefaultPort: Int
    private var storedHeartbeatInterval: TimeInterval
    private var storedRequestTimeout: TimeInterval

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

    /// How heavy the cue number is set.
    ///
    /// The drawer is deliberately unaffected: its weights are *relative* —
    /// the row standing by is heavier than the rows around it — and that
    /// hierarchy is what makes the list readable at a glance. Letting this
    /// pick one weight for every row would flatten it.
    var fontWeight: FontWeightChoice {
        didSet { defaults.set(fontWeight.rawValue, forKey: Key.fontWeight) }
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
        get { storedDrawerRowsAbove }
        set {
            storedDrawerRowsAbove = Limits.drawerRows.clamping(newValue)
            defaults.set(storedDrawerRowsAbove, forKey: Key.drawerRowsAboveCount)
        }
    }

    /// How many rows of the cue list the drawer shows below the playhead.
    var drawerRowsBelowCount: Int {
        get { storedDrawerRowsBelow }
        set {
            storedDrawerRowsBelow = Limits.drawerRows.clamping(newValue)
            defaults.set(storedDrawerRowsBelow, forKey: Key.drawerRowsBelowCount)
        }
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

    /// How large the pills are drawn.
    var pillSize: PillSize {
        didSet { defaults.set(pillSize.rawValue, forKey: Key.pillSize) }
    }

    /// Whether the cue-type pill spells out the type beside its glyph.
    ///
    /// Only the cue-type pill offers this. Its symbol already names its value
    /// — a speaker is an audio cue — so the word beside it is the one piece of
    /// pill text that can go without leaving a pill that says nothing. On by
    /// default, because an unfamiliar glyph is worse than a redundant one.
    var showsCueTypeLabel: Bool {
        didSet { defaults.set(showsCueTypeLabel, forKey: Key.showsCueTypeLabel) }
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

    /// The port the Add Server sheet starts from.
    ///
    /// Clamped rather than merely offered within bounds: this one is typed into
    /// a text field, not stepped, so nothing else stops an operator entering a
    /// port that the sheet will then refuse to accept.
    var defaultPort: Int {
        get { storedDefaultPort }
        set {
            storedDefaultPort = Limits.port.clamping(newValue)
            defaults.set(storedDefaultPort, forKey: Key.defaultPort)
        }
    }

    /// Seconds between `/thump` messages.
    var heartbeatInterval: TimeInterval {
        get { storedHeartbeatInterval }
        set {
            storedHeartbeatInterval = Limits.heartbeatInterval.clamping(newValue)
            defaults.set(storedHeartbeatInterval, forKey: Key.heartbeatInterval)
        }
    }

    /// Seconds before an unanswered request fails.
    var requestTimeout: TimeInterval {
        get { storedRequestTimeout }
        set {
            storedRequestTimeout = Limits.requestTimeout.clamping(newValue)
            defaults.set(storedRequestTimeout, forKey: Key.requestTimeout)
        }
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
        // `.bold` is what the cue number was set at before this was a choice,
        // so an existing install looks unchanged until the operator says
        // otherwise.
        fontWeight = defaults.string(forKey: Key.fontWeight)
            .flatMap(FontWeightChoice.init(rawValue:)) ?? .bold

        showsCueName = defaults.object(forKey: Key.showsCueName) as? Bool ?? true
        showsDrawer = defaults.object(forKey: Key.showsDrawer) as? Bool ?? true
        // Seeded through the backing stores, since the clamping setters cannot
        // run before `self` is fully initialised — hence the clamp at each one
        // here. This is the half the setters cannot cover: they guard what the
        // *app* assigns, and these guard what was already in `UserDefaults`,
        // written by an earlier build, by `defaults write`, or by a synced
        // preference file.
        storedDrawerRowsAbove = Limits.drawerRows.clamping(
            defaults.object(forKey: Key.drawerRowsAboveCount) as? Int ?? 3
        )
        storedDrawerRowsBelow = Limits.drawerRows.clamping(
            defaults.object(forKey: Key.drawerRowsBelowCount) as? Int ?? 3
        )

        pillOrder = Self.loadPillOrder(from: defaults)
        enabledPills = Self.loadEnabledPills(from: defaults)
        // The stored default is the size the pills were drawn at before this
        // was a choice, so an existing install looks unchanged until the
        // operator says otherwise.
        pillSize = defaults.string(forKey: Key.pillSize)
            .flatMap(PillSize.init(rawValue:)) ?? .default
        showsCueTypeLabel = defaults.object(forKey: Key.showsCueTypeLabel) as? Bool ?? true

        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)

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
        static let fontWeight = "fontWeight"
        static let showsCueName = "showsCueName"
        static let showsDrawer = "showsDrawer"
        // Spelled as they were first persisted. Renaming the properties above
        // must not reset a setting the operator already chose.
        static let drawerRowsAboveCount = "drawerPreviousCount"
        static let drawerRowsBelowCount = "drawerUpcomingCount"
        static let pillOrder = "pillOrder"
        static let enabledPills = "enabledPills"
        static let pillSize = "pillSize"
        static let showsCueTypeLabel = "showsCueTypeLabel"
        static let keepsDisplayAwake = "keepsDisplayAwake"
        static let defaultPort = "defaultPort"
        static let heartbeatInterval = "heartbeatInterval"
        static let requestTimeout = "requestTimeout"
        static let autoConnect = "autoConnect"
        static let lastServerID = "lastServerID"
        static let lastWorkspaceID = "lastWorkspaceID"
    }
}

extension ClosedRange {
    /// The value itself, or the nearest bound if it falls outside the range.
    ///
    /// The standard library's `clamped(to:)` clamps a *range* to another range;
    /// this clamps a single value, which is what ``Preferences/Limits`` is for.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
