import SwiftUI

/// Window identifiers for the auxiliary windows, so `openWindow` calls are typo-proof.
enum WindowID: String {
    case activityLog = "activity-log"
    case connectionInspector = "connection-inspector"
}

@main
struct CuetyApp: App {
    /// The single source of truth for connection state, cue data, and logging.
    /// Created once here and shared with every scene through the environment.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
