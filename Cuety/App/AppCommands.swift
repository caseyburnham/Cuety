import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

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

        CommandMenu("Connection") {
            Button("Refresh Connections") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canRefresh)

            Button("Add Server…") {
                model.isAddingServer = true
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Disconnect") {
                model.disconnect()
            }
            .disabled(!model.canDisconnect)

            Divider()

            WorkspaceMenuItems(model: model)
        }
    }
}
