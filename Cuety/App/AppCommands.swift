import SwiftUI

/// Cuety's menu bar commands.
///
/// Everything reachable by mouse is also reachable from the menu bar with a
/// keyboard shortcut, which is both a HIG expectation and a practical one —
/// an operator mid-show should not have to hunt for a control.
struct AppCommands: Commands {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.isPresenting ? "Exit Presentation Mode" : "Enter Presentation Mode") {
                model.togglePresentationMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Toggle("Cue Drawer", isOn: Binding(
                get: { model.preferences.showsDrawer },
                set: { _ in model.toggleDrawer() }
            ))
            .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()
        }

        CommandGroup(before: .windowList) {
            Button("Activity Log") {
                openWindow(id: WindowID.activityLog.rawValue)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Connection Status") {
                openWindow(id: WindowID.connectionInspector.rawValue)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()
        }
    }
}
