import SwiftUI

/// Every workspace Cuety can currently see, as menu items grouped by the
/// machine it is open on.
///
/// One definition, two menus: the Connection menu in the main menu bar, and
/// the menu behind Cuety's menu bar item. The sidebar is the primary way to
/// pick a workspace, but it can be collapsed, in presentation mode it is
/// hidden outright, and the menu bar item exists precisely for when Cuety's
/// window is not in front at all. An operator who needs to change workspace
/// mid-show should not have to bring any chrome back to do it.
///
/// Takes the model as a parameter rather than reading the environment, because
/// one of its two callers cannot offer one: ``AppCommands`` is a `Commands`
/// builder attached to a scene, which sits outside the window content that
/// `.environment(model)` is applied to.
struct WorkspaceMenuItems: View {
    let model: AppModel

    var body: some View {
        let servers = model.browser.orderedServers.filter { !$0.workspaces.isEmpty }

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
