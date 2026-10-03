import ShowControlUI
import SwiftUI

enum WindowID: String {
    case main = "main"
    case stats = "stats"
    case eventHistory = "event-history"
    case activityLog = "activity-log"
    case connectionInspector = "connection-inspector"
}

@MainActor
struct CuetyHostedContent<Content: View>: View {
    let model: AppModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(model)
            .preferredColorScheme(model.preferences.appearance.colorScheme)
            .reducingMotionWhenRequested()
    }
}

@main
@MainActor
struct CuetyApp: App {
    @State private var model = AppModel()

    /// The aggregate phase of every scene, rather than one window's.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
#if os(macOS)
        Window("Cuety", id: WindowID.main.rawValue) {
            CuetyHostedContent(model: model) {
                MainWindowView()
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("0", modifiers: .command)
        .onChange(of: scenePhase) { _, phase in
            model.updateScenePhase(phase)
        }
        .commands {
            AppCommands(model: model)
        }

        Window("Activity Log", id: WindowID.activityLog.rawValue) {
            CuetyHostedContent(model: model) {
                ActivityLogView()
                    .frame(minWidth: 600, minHeight: 320)
            }
        }
        .defaultSize(width: 780, height: 460)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Window("Connection Status", id: WindowID.connectionInspector.rawValue) {
            CuetyHostedContent(model: model) {
                ConnectionInspectorView()
                    .frame(minWidth: 400, minHeight: 360)
            }
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("i", modifiers: [.command, .shift])

        Window("Stats", id: WindowID.stats.rawValue) {
            CuetyHostedContent(model: model) {
                StatsView()
                    .frame(minWidth: 460, minHeight: 400)
            }
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Window("Event History", id: WindowID.eventHistory.rawValue) {
            CuetyHostedContent(model: model) {
                EventHistoryView()
                    .frame(minWidth: 460, minHeight: 320)
            }
        }
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("e", modifiers: [.command, .shift])

        MenuBarExtra(isInserted: Bindable(model.preferences).showsMenuBarExtra) {
            CuetyHostedContent(model: model) {
                CueMenuBarContent(model: model)
            }
        } label: {
            CuetyHostedContent(model: model) {
                CueMenuBarLabel()
            }
        }

        Settings {
            CuetyHostedContent(model: model) {
                SettingsView()
            }
        }
        .windowResizability(.contentSize)
#else
        WindowGroup {
            CuetyHostedContent(model: model) {
                MainWindowView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.updateScenePhase(phase)
        }
#endif
    }
}
