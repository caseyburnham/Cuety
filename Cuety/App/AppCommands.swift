import SwiftUI

/// Cuety's menu bar commands.
///
/// Everything reachable by mouse is also reachable from the menu bar with a
/// keyboard shortcut, which is both a HIG expectation and a practical one —
/// an operator mid-show should not have to hunt for a control.
struct AppCommands: Commands {
    let model: AppModel

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
        }

        // Connection actions get their own menu rather than being appended to
        // View: they act on the QLab session, not on what the window shows.
        // The Activity Log and Connection Status windows are deliberately absent
        // here — a `Window` scene already contributes its own Window-menu item,
        // and its `keyboardShortcut` binds to that item, so adding buttons for
        // them would produce a second copy of each command.
        CommandMenu("Connection") {
            Button("Refresh") {
                Task { await model.refreshWorkspaces() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)

            Divider()

            Button("Disconnect") {
                model.disconnect()
            }
            .disabled(!model.client.status.hasLiveData)
        }
    }
}
