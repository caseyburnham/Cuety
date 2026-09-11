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

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
    }
}
