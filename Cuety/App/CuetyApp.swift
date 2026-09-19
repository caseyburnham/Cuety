import SwiftUI

enum WindowID: String {
    case main = "main"
    case activityLog = "activity-log"
    case connectionInspector = "connection-inspector"
}

@main
@MainActor
struct CuetyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
#if os(macOS)
        Window("Cuety", id: WindowID.main.rawValue) {
            MainWindowView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 900, height: 560)
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
#else
        WindowGroup {
            MainWindowView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }

#endif
    }
}
