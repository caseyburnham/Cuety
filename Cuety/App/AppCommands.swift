#if os(macOS)
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Toggle("Cue List Layout", isOn: Binding(
                get: { model.preferences.cueLayout == .list },
                set: { model.setCueLayout($0 ? .list : .display) }
            ))
            .keyboardShortcut("l", modifiers: [.command, .option])

            Toggle("Cue Drawer", isOn: Binding(
                get: { model.preferences.showsDrawer },
                set: { model.setShowsDrawer($0) }
            ))
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(model.preferences.cueLayout == .list)

            Toggle("Standby Dossier", isOn: Bindable(model).isDossierVisible)
                .keyboardShortcut("d", modifiers: [.command, .shift])
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
#endif
