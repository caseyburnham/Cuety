import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    @State private var isConnecting = false

    /// Workspaces the operator has collapsed. A connected workspace shows its
    /// cue lists by default, so absence from this set means expanded.
    @State private var collapsedWorkspaces: Set<WorkspaceSelection> = []

    private enum Selection: Hashable {
        case workspace(WorkspaceSelection)
        case cueList(String)
    }

    var body: some View {
        List(selection: sidebarSelection) {
            ForEach(visibleServers) { server in
                serverSection(server)
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
            if let item = items.first { activate(item) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
#if os(iOS)
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Server", systemImage: "plus") {
                    model.isAddingServer = true
                }
                .accessibilityHint("Add a QLab server by host name or address")
            }
            // Only a collapsed split view strands the operator here. At regular
            // widths the display is already on screen beside the sidebar and the
            // split view supplies its own toggle.
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.isSidebarVisible = false
                    } label: {
                        Image(systemName: "rectangle.rightthird.inset.filled")
                    }
                    .accessibilityLabel("Show Cue Display")
                }
            }
        }
        // At regular widths the cue display beside the sidebar carries the
        // status controls. The floating display stays for portrait, where
        // the sidebar slides over and hides the cue display.
        .compactToolbarActions(showsStatusActions: horizontalSizeClass == .compact)
#endif
    }

    @ViewBuilder
    private func serverSection(_ server: QLabServer) -> some View {
        Section {
            ForEach(server.workspaces, id: \.uniqueID) { workspace in
                erasedWorkspaceRow(workspace, on: server)
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
                        .transition(reduceMotion ? .identity : .opacity)
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

#if os(iOS)
    private var visibleServers: [QLabServer] {
        model.browser.orderedServers.filter { $0.name != "This Mac" }
    }
#else
    private var visibleServers: [QLabServer] { model.browser.orderedServers }
#endif

    private var sidebarSelection: Binding<Selection?> {
        Binding {
            if model.client.status.hasLiveData, let id = model.client.watchedCueListID {
                return .cueList(id)
            }
            return model.selection.map(Selection.workspace)
        } set: { selection in
            if let selection { activate(selection) }
        }
    }

    /// A tap reaches a row through the list's primary action rather than the
    /// selection binding, so both routes land here. Each branch is idempotent,
    /// which keeps a platform that calls both harmless.
    private func activate(_ selection: Selection) {
        switch selection {
        case .workspace(let workspace):
            connect(to: workspace)
        case .cueList(let id):
            watch(cueListWithID: id)
        }
    }

    private func watch(cueListWithID id: String) {
        guard id != model.client.watchedCueListID else { return }
        withAnimation(reduceMotion ? nil : Motion.cueChange) {
            model.client.watchedCueListID = id
        }
        Task { await model.client.refreshPlayheadCueDetails() }
    }

    /// A workspace only knows its cue lists while Cuety is connected to it, so
    /// only the live workspace opens; the rest stay plain rows.
    @ViewBuilder
    private func workspaceRow(_ workspace: QLabWorkspaceInfo, on server: QLabServer) -> some View {
        let selection = WorkspaceSelection(serverID: server.id, workspaceID: workspace.uniqueID)

        if model.selection == selection && model.client.status.hasLiveData {
            DisclosureGroup(isExpanded: isExpanded(selection)) {
                ForEach(model.client.cueLists) { list in
                    cueListRow(list)
                }
                if model.client.cueLists.isEmpty {
                    Text("No Cue Lists")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } label: {
                workspaceLabel(workspace, selection: selection)
            }
        } else {
            workspaceLabel(workspace, selection: selection)
        }
    }

    /// This row contains a platform-dependent DisclosureGroup/List selection tree.
    /// Erasing only this branch keeps SwiftUI's surrounding Section builder tractable
    /// on both the macOS and iPad compilers without changing the rendered hierarchy.
    private func erasedWorkspaceRow(
        _ workspace: QLabWorkspaceInfo, on server: QLabServer
    ) -> AnyView {
        AnyView(workspaceRow(workspace, on: server))
    }

    private func isExpanded(_ selection: WorkspaceSelection) -> Binding<Bool> {
        Binding {
            !collapsedWorkspaces.contains(selection)
        } set: { expanded in
            if expanded {
                collapsedWorkspaces.remove(selection)
            } else {
                collapsedWorkspaces.insert(selection)
            }
        }
    }

    private func workspaceLabel(
        _ workspace: QLabWorkspaceInfo, selection: WorkspaceSelection
    ) -> some View {
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
        .accessibilityHint(
            isCurrent ? "The connected workspace" : "Double-click to connect to this workspace"
        )
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
