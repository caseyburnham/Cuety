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
    @State private var newPort = String(QLabServer.defaultPort)

    var body: some View {
        List(selection: selectionBinding) {
            if !model.browser.bonjourServers.isEmpty {
                Section("Bonjour") {
                    ForEach(model.browser.bonjourServers) { server in
                        serverRow(server)
                    }
                }
            }

            Section("Local") {
                ForEach(model.browser.manualServers) { server in
                    serverRow(server)
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
                }
                .help("Ask every server for its open workspaces")
            }
        }
        .sheet(isPresented: $isAddingServer) {
            addServerSheet
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func serverRow(_ server: QLabServer) -> some View {
        DisclosureGroup {
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
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                    Text(server.displayEndpoint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: server.source == .bonjour ? "network" : "desktopcomputer")
            }
        }
        .contextMenu {
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
        let isConnected = model.selection == selection && model.client.status.hasLiveData

        DisclosureGroup(isExpanded: .constant(isConnected)) {
            if isConnected {
                ForEach(model.client.cueLists) { list in
                    cueListRow(list)
                }
            }
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(workspace.displayName)
                    if model.passcodes.hasPasscode(
                        serverID: server.id, workspaceID: workspace.uniqueID
                    ) {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("A passcode for this workspace is saved in your Keychain")
                    }
                }
            } icon: {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "doc.text")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .tag(selection)
    }

    @ViewBuilder
    private func cueListRow(_ list: Cue) -> some View {
        let isWatched = model.client.watchedCueListID == list.uniqueID

        Button {
            withAnimation(Motion.cueChange) {
                model.client.watchedCueListID = list.uniqueID
            }
            Task { await model.client.refreshPlayheadCueDetails() }
        } label: {
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
                Image(systemName: isWatched ? "eye.fill" : "list.bullet")
                    .foregroundStyle(isWatched ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .fontWeight(isWatched ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    /// Selecting a workspace connects to it; deselecting disconnects.
    private var selectionBinding: Binding<WorkspaceSelection?> {
        Binding {
            model.selection
        } set: { newValue in
            guard let newValue else {
                model.disconnect()
                return
            }
            guard newValue != model.selection else { return }
            Task { await model.connect(to: newValue) }
        }
    }

    // MARK: - Overlays and sheets

    private var searchingOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: model.browser.isBrowsing)

            Text("Looking for QLab")
                .font(.callout)
            Text("Open a workspace in QLab 5 on this Mac or on the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
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
            HStack {
                Button("Cancel", role: .cancel) { dismissAddServer() }
                Spacer()
                Button("Add") { addServer() }
                    .buttonStyle(.borderedProminent)
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
        newPort = String(QLabServer.defaultPort)
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
