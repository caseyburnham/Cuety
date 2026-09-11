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
            // Named for what it does rather than the vaguer "Refresh": this
            // restarts discovery and rebuilds the session, which momentarily
            // interrupts the cue display. ⌘R is easy to hit by accident, so the
            // menu item should not undersell it.
            //
            // Availability comes from ``AppModel`` rather than being tested
            // here, so the menu and its keyboard shortcut cannot disagree with
            // the sidebar or the inspector about whether an action is possible.
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

            workspaceItems
        }
    }

    /// Every workspace Cuety can currently see, grouped by the machine it is
    /// open on.
    ///
    /// The sidebar is the primary way to pick one, but it can be collapsed —
    /// and in presentation mode it is hidden outright. An operator who needs to
    /// change workspace mid-show should not have to bring the chrome back to do
    /// it.
    @ViewBuilder
    private var workspaceItems: some View {
        let servers = (model.browser.manualServers + model.browser.bonjourServers)
            .filter { !$0.workspaces.isEmpty }

        if servers.isEmpty {
            // Disabled rather than absent: an empty menu section reads as a
            // broken menu, while this says plainly that nothing was found.
            Button("No Workspaces Found") {}
                .disabled(true)
        } else {
            ForEach(servers) { server in
                Section(server.name) {
                    ForEach(server.workspaces) { workspace in
                        workspaceItem(workspace, on: server)
                    }
                }
            }
        }
    }

    private func workspaceItem(
        _ workspace: QLabWorkspaceInfo, on server: QLabServer
    ) -> some View {
        let selection = WorkspaceSelection(
            serverID: server.id, workspaceID: workspace.uniqueID
        )
        let isCurrent = model.selection == selection

        return Button {
            Task { await model.connect(to: selection) }
        } label: {
            // A checkmark on the current workspace, which is the standard way a
            // macOS menu shows which of several things is selected.
            if isCurrent {
                Label(workspace.displayName, systemImage: "checkmark")
            } else {
                Text(workspace.displayName)
            }
        }
        // Connecting to the workspace already connected to is a no-op, and
        // offering it invites the operator to interrupt their own show for
        // nothing.
        .disabled(isCurrent || !model.canConnect)
    }
}
