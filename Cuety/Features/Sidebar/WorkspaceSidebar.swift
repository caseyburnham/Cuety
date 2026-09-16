import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isConnecting = false

    private enum Selection: Hashable {
        case workspace(WorkspaceSelection)
        case cueList(String)
    }

    var body: some View {
        List(selection: sidebarSelection) {
            ForEach(model.browser.orderedServers) { server in
                Section {
                    ForEach(server.workspaces) { workspace in
                        workspaceRow(workspace, on: server)
                    }
                    if server.workspaces.isEmpty {
                        serverStatus(server)
                            .selectionDisabled()
                            .contextMenu {
                                removeServerButton(server)
                            }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(server.name)
                        if model.refreshingServerIDs.contains(server.id) {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.blurReplace)
                                .accessibilityLabel("Looking for workspaces on \(server.name)")
                        }
                    }
                    .motion(
                        Motion.status,
                        value: model.refreshingServerIDs.contains(server.id)
                    )
                    .help(server.address ?? "Discovered on the local network")
                    .contextMenu {
                        removeServerButton(server)
                    }
                }
            }

            if model.client.status.hasLiveData {
                Section("Cue Lists") {
                    ForEach(model.client.cueLists) { list in
                        cueListRow(list)
                    }
                    if model.client.cueLists.isEmpty {
                        Text("No Cue Lists")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }

            if let error = model.browser.browseError {
                Section("Network Discovery") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .contextMenu(forSelectionType: Selection.self) { items in
            if case .workspace(let selection) = items.first {
                if model.selection == selection && model.canDisconnect {
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button("Connect") { connect(to: selection) }
                        .disabled(!model.canConnect)
                }
                if let server = model.browser.server(withID: selection.serverID) {
                    removeServerButton(server)
                }
            }
        } primaryAction: { items in
            if case .workspace(let selection) = items.first {
                connect(to: selection)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var sidebarSelection: Binding<Selection?> {
        Binding {
            if model.client.status.hasLiveData, let id = model.client.watchedCueListID {
                return .cueList(id)
            }
            return model.selection.map(Selection.workspace)
        } set: { selection in
            guard case .cueList(let id) = selection,
                  id != model.client.watchedCueListID
            else { return }
            withAnimation(reduceMotion ? nil : Motion.cueChange) {
                model.client.watchedCueListID = id
            }
            Task { await model.client.refreshPlayheadCueDetails() }
        }
    }

    private func workspaceRow(_ workspace: QLabWorkspaceInfo, on server: QLabServer) -> some View {
        let selection = WorkspaceSelection(serverID: server.id, workspaceID: workspace.uniqueID)
        let isCurrent = model.selection == selection

        return Label {
            HStack {
                Text(workspace.displayName)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if isCurrent {
                    if model.client.status.isTransitional {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.client.status.systemImage)
                            .foregroundStyle(model.client.status.tint)
                            .help(model.client.status.title)
                            .accessibilityLabel(model.client.status.title)
                    }
                }
            }
        } icon: {
            Image(systemName: "list.bullet.below.rectangle")
        }
        .tag(Selection.workspace(selection))
        .help(workspace.displayName)
        .accessibilityHint("Double-click to connect to this workspace")
    }

    private func connect(to selection: WorkspaceSelection) {
        guard !isConnecting, model.canConnect else { return }
        guard selection != model.selection || !model.client.status.hasLiveData else { return }
        isConnecting = true
        Task {
            defer { isConnecting = false }
            await model.connect(to: selection)
        }
    }

    @ViewBuilder
    private func removeServerButton(_ server: QLabServer) -> some View {
        if model.canRemove(server) {
            Button("Remove Server", role: .destructive) {
                model.removeServer(withID: server.id)
            }
        }
    }

    @ViewBuilder
    private func serverStatus(_ server: QLabServer) -> some View {
        if model.refreshingServerIDs.contains(server.id) {
            Text("Looking for workspaces…")
                .foregroundStyle(.secondary)
        } else if let error = server.lastError {
            Label("Unable to Reach QLab", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help(error)
        } else if !server.hasBeenProbed {
            Button("Check for Workspaces") { probeWorkspaces(on: server) }
                .help("Cuety hasn't contacted \(server.name) yet.")
        } else {
            Text("No Open Workspaces")
                .foregroundStyle(.secondary)
        }
    }

    private func cueListRow(_ list: Cue) -> some View {
        let state = model.client.playheads[list.uniqueID]
        let cue = state?.cueID.flatMap { list.children.firstCue(withID: $0) }

        let marker: String
        let description: String
        switch state {
        case .cue where cue != nil:
            marker = cue?.displayNumber ?? "•"
            description = """
                Standing by: \(cue?.displayNumber ?? "Unnumbered cue"), \
                \(cue?.displayName ?? "Untitled")
                """
        case .cue:
            marker = "?"
            description = "Standing by a cue Cuety has not caught up with yet"
        case .unset:
            marker = "—"
            description = "No cue standing by"
        case .unknown(let reason):
            marker = "?"
            description = "Playhead unknown. \(reason)"
        case nil:
            marker = "·"
            description = "Cuety has not read this cue list's playhead yet"
        }

        return Label {
            HStack {
                Text(list.displayName ?? "Untitled Cue List")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(marker)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(state?.isKnown == false ? .orange : .secondary)
                    .help(description)
                    .accessibilityLabel(description)
            }
        } icon: {
            Image(systemName: "list.triangle")
        }
        .tag(Selection.cueList(list.uniqueID))
        .help(list.displayName ?? "Untitled Cue List")
        .accessibilityHint("Watches this cue list's playhead")
    }

    private func probeWorkspaces(on server: QLabServer) {
        Task { await model.refreshWorkspaces(onServerWithID: server.id) }
    }
}
