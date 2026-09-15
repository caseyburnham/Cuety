import SwiftUI

/// Window identifiers, so `openWindow` calls and scene declarations are
/// typo-proof.
enum WindowID: String {
    case main = "main"
    case activityLog = "activity-log"
    case connectionInspector = "connection-inspector"
}

@main
struct CuetyApp: App {
    /// The single source of truth for connection state, cue data, and logging.
    /// Created once here and shared with every scene through the environment.
    @State private var model = AppModel()

    var body: some Scene {
        // `Window`, not `WindowGroup`: exactly one cue display, ever.
        //
        // A group let File ▸ New Window produce a second main window, and every
        // main window ran `model.start()` — so opening one started another
        // untracked task that restarted discovery and could reconnect the
        // session both windows shared. Presentation mode and sidebar visibility
        // were shared regardless, since both live on ``AppModel``, so a second
        // window was never really a second display; it was a second remote
        // control for the first one.
        //
        // The cost is deliberate: Cuety can no longer put a duplicate cue
        // display on a second monitor. That was never built, and it is not what
        // a group was giving anyone.
        Window("Cuety", id: WindowID.main.rawValue) {
            MainWindowView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 900, height: 560)
        // Brings the cue display back after it has been closed. A `Window`
        // scene contributes its own Window-menu item, and the shortcut binds
        // to that item — ⌘0 because Mail uses it for the same job, reopening
        // the one window the app is really about.
        .keyboardShortcut("0", modifiers: .command)
        .commands {
            AppCommands(model: model)
        }

        Window("Activity Log", id: WindowID.activityLog.rawValue) {
            ActivityLogView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 780, height: 460)
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Window("Connection Status", id: WindowID.connectionInspector.rawValue) {
            ConnectionInspectorView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("i", modifiers: [.command, .shift])

        // Cuety's readout in the system menu bar, off until the operator asks
        // for it in Settings.
        //
        // `isInserted` is a two-way binding, which is the reason to use it
        // rather than putting this scene behind an `if`: ⌘-dragging the item
        // off the menu bar is how macOS expects one to be removed, and that
        // gesture writes `false` straight back to the preference. The Settings
        // toggle and the menu bar therefore cannot end up disagreeing about
        // whether the item is there.
        //
        // No `menuBarExtraStyle`: `.menu` is the default and is what this
        // wants — a list of commands, not a window.
        MenuBarExtra(isInserted: Bindable(model.preferences).showsMenuBarExtra) {
            CueMenuBarContent(model: model)
                .environment(model)
        } label: {
            CueMenuBarLabel()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
    }
}
