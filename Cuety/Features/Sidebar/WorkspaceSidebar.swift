import SwiftUI

/// The workspace list: servers grouped by how Cuety found them, each disclosing
/// its open workspaces, each connected workspace disclosing its cue lists.
///
/// Cue lists are selectable because "which list is the active one" has no
/// documented getter in QLab's OSC dictionary. Letting the operator say which
/// list to watch is both a workaround for that and the better behaviour: on a
/// multi-list show, they may well want to watch a specific one.
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model

    @State private var isAddingServer = false
    @State private var newHost = ""
    /// Seeded from the preference when the sheet opens, so a house that runs
    /// QLab on a non-standard port sets it once in Settings.
    @State private var newPort = ""
    @State private var expandedServerIDs: Set<String> = []
    @State private var expandedWorkspaceIDs: Set<String> = []

    var body: some View {
        List(selection: watchedCueList) {
            if !model.browser.bonjourServers.isEmpty {
                Section("Bonjour") {
                    ForEach(model.browser.bonjourServers) { server in
                        serverRow(server)
                    }
                }
            }

            if !model.browser.manualServers.isEmpty {
                Section {
                    ForEach(model.browser.manualServers) { server in
                        serverRow(server)
                    }
                } header: {
                    Text("Local")
                } footer: {
                    if let date = model.lastRefreshDate {
                        HStack(spacing: 4) {
                            Text("Updated")
                            Text(date, style: .time)
                        }
                    }
                }
            }

            if let error = model.browser.browseError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .overlay {
            if model.browser.servers.allSatisfy(\.workspaces.isEmpty),
               model.browser.bonjourServers.isEmpty {
                searchingOverlay
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    newPort = String(model.preferences.defaultPort)
                    isAddingServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .help("Connect to QLab at a specific address")
            }

            ToolbarItem {
                Button {
                    Task { await model.refreshWorkspaces() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        // The symbol animates itself while the refresh is in
                        // flight, which keeps the button's size and position
                        // fixed — swapping in a `ProgressView` would not.
                        .symbolEffect(
                            .rotate.byLayer,
                            options: .repeat(.continuous),
                            isActive: model.isRefreshing
                        )
                }
                .disabled(model.isRefreshing)
                .help("Ask every server for its open workspaces")
            }
        }
        .sheet(isPresented: $isAddingServer) {
            addServerSheet
        }
    }

    // MARK: - Selection

    /// Drives the list's native selection from the watched cue list.
    ///
    /// Only cue list rows carry a `tag`, so servers and workspaces stay
    /// unselectable while the cue lists get the system's sidebar highlight
    /// instead of a hand-drawn row background.
    private var watchedCueList: Binding<String?> {
        Binding {
            model.client.watchedCueListID
        } set: { newValue in
            // Clicking empty space clears selection; that shouldn't stop us
            // watching the list the operator already chose.
            guard let newValue, newValue != model.client.watchedCueListID else { return }
            withAnimation(Motion.cueChange) {
                model.client.watchedCueListID = newValue
            }
            Task { await model.client.refreshPlayheadCueDetails() }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func serverRow(_ server: QLabServer) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: server.id)) {
            if server.workspaces.isEmpty {
                Label(
                    server.lastError == nil ? "No open workspaces" : "Unreachable",
                    systemImage: server.lastError == nil ? "tray" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(server.lastError == nil ? Color.secondary : Color.orange)
                .help(server.lastError ?? "QLab has no workspaces open on this machine.")
            } else {
                ForEach(server.workspaces) { workspace in
                    workspaceRow(workspace, on: server)
                }
            }
        } label: {
            // No button wrapper: a `DisclosureGroup` label already toggles the
            // group when clicked, and wrapping it stole that behaviour along
            // with the row's native highlight.
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                    Text(server.displayEndpoint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: server.source == .bonjour ? "bonjour" : "desktopcomputer")
            }
        }
        .contextMenu {
            if model.selection?.serverID == server.id, model.client.status.hasLiveData {
                Button("Disconnect") {
                    model.disconnect()
                }
            }
            if server.source == .manual, server.id != QLabServer.localhost().id {
                Button("Remove Server", role: .destructive) {
                    model.browser.removeManualServer(id: server.id)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceRow(
        _ workspace: QLabWorkspaceInfo,
        on server: QLabServer
    ) -> some View {
        let selection = WorkspaceSelection(
            serverID: server.id, workspaceID: workspace.uniqueID
        )
        let selectionID = "\(server.id)|\(workspace.uniqueID)"
        let isConnected = model.selection == selection && model.client.status.hasLiveData

        DisclosureGroup(isExpanded: workspaceExpansionBinding(for: selectionID)) {
            if isConnected {
                ForEach(model.client.cueLists) { list in
                    cueListRow(list)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(workspace.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.passcodes.hasPasscode(
                    serverID: server.id, workspaceID: workspace.uniqueID
                ) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("A passcode for this workspace is saved in your Keychain")
                }

                // The icon reports connection state and stays put; what a click
                // does is in the tooltip. Morphing it to a red ✗ under the
                // pointer meant the row's meaning changed on hover, which is
                // not something macOS controls do.
                Button {
                    if isConnected {
                        model.disconnect()
                    } else {
                        Task { await model.connect(to: selection) }
                    }
                } label: {
                    Image(systemName: isConnected ? "checkmark.circle.fill" : "link.circle")
                        .foregroundStyle(isConnected ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help(isConnected
                    ? "Connected. Click to disconnect."
                    : "Connect to this workspace")
                .accessibilityLabel(isConnected ? "Disconnect" : "Connect")
            }
        }
        .contextMenu {
            // Both cases covered, so a right-click never opens an empty menu.
            if isConnected {
                Button("Disconnect") {
                    model.disconnect()
                }
            } else {
                Button("Connect") {
                    Task { await model.connect(to: selection) }
                }
            }
        }
    }

    /// A selectable row. Selection *is* the watched-list state, so the row
    /// carries no highlight of its own — the sidebar draws the standard one.
    @ViewBuilder
    private func cueListRow(_ list: Cue) -> some View {
        let isWatched = model.client.watchedCueListID == list.uniqueID

        Label {
            HStack {
                Text(list.displayName ?? "Untitled Cue List")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.client.playheads[list.uniqueID] == nil {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("This cue list has no playhead set")
                }
            }
        } icon: {
            Image(systemName: isWatched ? "eye" : "eye.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .tag(list.uniqueID)
        .accessibilityHint("Watches this cue list's playhead")
    }

    private func workspaceExpansionBinding(for workspaceID: String) -> Binding<Bool> {
        Binding {
            expandedWorkspaceIDs.contains(workspaceID)
        } set: { isExpanded in
            if isExpanded {
                expandedWorkspaceIDs.insert(workspaceID)
            } else {
                expandedWorkspaceIDs.remove(workspaceID)
            }
        }
    }

    private func expansionBinding(for serverID: String) -> Binding<Bool> {
        Binding {
            expandedServerIDs.contains(serverID)
        } set: { isExpanded in
            if isExpanded {
                expandedServerIDs.insert(serverID)
            } else {
                expandedServerIDs.remove(serverID)
            }
        }
    }

    // MARK: - Overlays and sheets

    private var searchingOverlay: some View {
        ContentUnavailableView {
            Label {
                Text("Looking for QLab")
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolEffect(
                        .variableColor.iterative,
                        isActive: model.browser.isBrowsing
                    )
            }
        } description: {
            Text("Open a workspace in QLab 5 on this Mac or on the network.")
        }
        .allowsHitTesting(false)
    }

    private var addServerSheet: some View {
        Form {
            Section {
                TextField("Host", text: $newHost, prompt: Text("192.168.1.10"))
                TextField("Port", text: $newPort, prompt: Text("53000"))
                    .monospacedDigit()
            } footer: {
                Text("QLab listens on port 53000 by default. A workspace with a custom OSC port reports it once connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .safeAreaInset(edge: .bottom) {
            // Both buttons at the trailing edge, confirmation last: the macOS
            // convention for a sheet's action row.
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismissAddServer() }
                Button("Add") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isNewServerValid)
            }
            .padding()
        }
    }

    private var isNewServerValid: Bool {
        guard !newHost.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let port = UInt16(newPort), port > 0 else { return false }
        return true
    }

    private func addServer() {
        guard let port = UInt16(newPort) else { return }
        let server = model.browser.addManualServer(
            host: newHost.trimmingCharacters(in: .whitespaces), port: port
        )
        dismissAddServer()

        // Ask the new server what it has straight away, so the row isn't empty.
        Task {
            if let workspaces = try? await model.client.fetchWorkspaces(from: server) {
                var updated = server
                updated.workspaces = workspaces
                model.browser.update(updated)
            }
        }
    }

    private func dismissAddServer() {
        isAddingServer = false
        newHost = ""
        newPort = ""
    }
}

#Preview {
    NavigationSplitView {
        WorkspaceSidebar()
            .environment(AppModel())
    } detail: {
        Text("Detail")
    }
}
