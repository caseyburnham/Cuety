import SwiftUI

struct WorkspaceMenuItems: View {
    let model: AppModel

    var body: some View {
        let servers = model.browser.orderedServers.filter { !$0.workspaces.isEmpty }

        if servers.isEmpty {
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
            if isCurrent {
                Label(workspace.displayName, systemImage: "checkmark")
            } else {
                Text(workspace.displayName)
            }
        }
        .disabled(isCurrent || !model.canConnect)
    }
}
