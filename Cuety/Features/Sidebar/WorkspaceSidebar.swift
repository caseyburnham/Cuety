import SwiftUI

/// The workspace list: servers grouped by how Cuety found them, each disclosing
/// its open workspaces, each connected workspace disclosing its cue lists.
///
/// The list's selection *is* the watched cue list, because the watched cue list
/// is what the detail pane shows — which is what a source list's selection means
/// on macOS. Servers and workspaces carry no tag and so aren't selectable: they
/// are containers and actions, not things the window can display.
///
/// Cue lists are selectable at all because "which list is the active one" has no
/// documented getter in QLab's OSC dictionary. Letting the operator say which
/// list to watch is both a workaround for that and the better behaviour: on a
/// multi-list show, they may well want to watch a specific one.
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model

    @State private var isAddingServer = false
    @State private var newHost = ""
    /// Seeded from the preference when the sheet opens, so a house that runs
    /// QLab on a non-standard port sets it once in Settings.
    @State private var newPort = Int(QLabServer.defaultPort)
    /// Servers the operator has *closed*, rather than the ones they've opened.
    /// Inverted deliberately: a new server arrives expanded, so its workspaces —
    /// or its "no open workspaces" explanation — are readable without a click.
    @State private var collapsedServerIDs: Set<String> = []

    var body: some View {
        List(selection: watchedCueList) {
            if !model.browser.bonjourServers.isEmpty {
                Section(QLabServer.Source.bonjour.sectionTitle) {
                    ForEach(model.browser.bonjourServers) { server in
                        serverRow(server)
                    }
                }
            }

            // Never empty: the localhost entry is always present.
            Section(QLabServer.Source.manual.sectionTitle) {
                ForEach(model.browser.manualServers) { server in
                    serverRow(server)
                }
            }

            if let error = model.browser.browseError {
                Section("Network") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .toolbar {
            ToolbarItem {
                Button {
                    // Reset both fields here rather than on dismissal, so the
                    // sheet is fresh however it was last closed.
                    newHost = ""
                    newPort = model.preferences.defaultPort
                    isAddingServer = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .help("Connect to QLab at a specific address")
            }

            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh Everything", systemImage: "arrow.clockwise")
                        // The symbol animates itself while the refresh is in
                        // flight, which keeps the button's size and position
                        // fixed — swapping in a `ProgressView` would not. It is
                        // also the app's only indication that Cuety is out
                        // looking, so it runs on launch as well as on demand.
                        //
                        // Periodic rather than continuous: each turn is a
                        // discrete eased animation, so the glyph accelerates and
                        // settles instead of grinding round at one speed. A zero
                        // delay runs them back to back, and the doubled speed
                        // reads as busy rather than as laboured.
                        .symbolEffect(
                            .rotate.byLayer,
                            options: .repeat(.periodic(delay: 0)).speed(2),
                            isActive: model.isRefreshing
                        )
                }
                .disabled(model.isRefreshing)
                .help(
                    """
                    Restart Bonjour discovery, re-ask every server for its open \
                    workspaces, and rebuild the connection to QLab from scratch.
                    """
                )
            }
        }
        .sheet(isPresented: $isAddingServer) {
            addServerSheet
        }
    }

    // MARK: - Selection

    /// Drives the list's native selection from the watched cue list.
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

    private func serverRow(_ server: QLabServer) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: server.id)) {
            if server.workspaces.isEmpty {
                Label(
                    server.lastError == nil ? "No open workspaces" : "Unreachable",
                    systemImage: server.lastError == nil ? "tray" : "exclamationmark.triangle"
                )
                .foregroundStyle(server.lastError == nil ? Color.secondary : Color.orange)
                .help(server.lastError ?? "QLab has no workspaces open on this machine.")
            } else {
                ForEach(server.workspaces) { workspace in
                    WorkspaceRow(workspace: workspace, server: server)
                }
            }
        } label: {
            // No button wrapper: a `DisclosureGroup` label already toggles the
            // group when clicked, and wrapping it stole that behaviour along
            // with the row's native highlight.
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                    // Absent for a Bonjour service, whose address is the
                    // system's to resolve and whose name is already above.
                    if let address = server.address {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: server.source == .bonjour ? "bonjour" : "desktopcomputer")
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

    private func expansionBinding(for serverID: String) -> Binding<Bool> {
        Binding {
            !collapsedServerIDs.contains(serverID)
        } set: { isExpanded in
            if isExpanded {
                collapsedServerIDs.remove(serverID)
            } else {
                collapsedServerIDs.insert(serverID)
            }
        }
    }

    // MARK: - Add Server

    private var addServerSheet: some View {
        Form {
            Section {
                TextField("Host", text: $newHost, prompt: Text("192.168.1.10"))
                TextField(
                    "Port",
                    value: $newPort,
                    format: .number.grouping(.never)
                )
                .monospacedDigit()
            } header: {
                Text("Add Server")
            } footer: {
                Text("A workspace with its own OSC port reports it once connected.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .safeAreaInset(edge: .bottom) {
            // Both buttons at the trailing edge, confirmation last: the macOS
            // convention for a sheet's action row.
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAddingServer = false }
                Button("Add") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isNewServerValid)
            }
            .padding()
        }
    }

    private var isNewServerValid: Bool {
        !newHost.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(exactly: newPort) != nil
            && newPort > 0
    }

    private func addServer() {
        guard let port = UInt16(exactly: newPort), port > 0 else { return }
        let server = model.browser.addManualServer(
            host: newHost.trimmingCharacters(in: .whitespaces), port: port
        )
        isAddingServer = false

        // Ask the new server what it has straight away, so the row isn't empty.
        Task {
            if let workspaces = try? await model.client.fetchWorkspaces(from: server) {
                var updated = server
                updated.workspaces = workspaces
                model.browser.update(updated)
            }
        }
    }
}

/// One open workspace, disclosing its cue lists once there are cue lists to
/// disclose.
///
/// A view of its own rather than a `@ViewBuilder` method on the sidebar so that
/// it can own its disclosure state.
private struct WorkspaceRow: View {
    let workspace: QLabWorkspaceInfo
    let server: QLabServer

    @Environment(AppModel.self) private var model

    /// Open by default, so connecting reveals the cue lists rather than leaving
    /// the operator to find a chevron while the detail pane asks them to pick a
    /// list. Only consulted while connected, since there is nothing to disclose
    /// otherwise.
    @State private var isExpanded = true

    private var selection: WorkspaceSelection {
        WorkspaceSelection(serverID: server.id, workspaceID: workspace.uniqueID)
    }

    private var isConnected: Bool {
        model.selection == selection && model.client.status.hasLiveData
    }

    var body: some View {
        row
            .animation(Motion.status, value: isConnected)
            .contextMenu {
                // Both cases covered, so a right-click never opens an empty menu.
                if isConnected {
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button("Connect") {
                        Task { await model.connect(to: selection) }
                    }
                }
            }
    }

    @ViewBuilder
    private var row: some View {
        if isConnected {
            // Connected, the row's only job on click is to open and close the
            // cue lists — which is exactly what a `DisclosureGroup` label does
            // on its own, so nothing else is layered on top of it.
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(model.client.cueLists) { list in
                    cueListRow(list)
                }
            } label: {
                label
            }
        } else {
            // Disconnected, there is nothing to disclose, so no chevron: a
            // chevron that opens onto nothing is an affordance that lies. The
            // row becomes the connect control instead, which is the one thing
            // an operator wants from a workspace they aren't watching yet.
            Button {
                Task { await model.connect(to: selection) }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Connect to this workspace")
            .accessibilityHint("Connects to this workspace")
        }
    }

    /// Name, then two pieces of state worth knowing before you click: whether
    /// Cuety already holds this workspace's passcode, and whether it is the one
    /// currently connected. Neither is a control — connecting and disconnecting
    /// live on the row itself, its context menu, and the Connection menu.
    private var label: some View {
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

            Image(systemName: isConnected ? "checkmark.circle.fill" : "link.circle")
                .foregroundStyle(isConnected ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .help(isConnected ? "Connected" : "Not connected")
                .accessibilityHidden(true)
        }
    }

    /// A selectable row. Selection *is* the watched-list state, so the row
    /// carries no watched marker of its own — the sidebar draws the standard
    /// highlight, and the trailing value is free to report something else.
    private func cueListRow(_ list: Cue) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(list.displayName ?? "Untitled Cue List")
                    .lineLimit(1)
                Spacer(minLength: 4)
                playhead(of: list)
            }
        } icon: {
            Image(systemName: "list.bullet")
        }
        .tag(list.uniqueID)
        .accessibilityHint("Watches this cue list's playhead")
    }

    /// Where this list is standing by.
    ///
    /// The reason to show it on an unselected row: on a multi-list show the
    /// operator can see every list's position at once instead of having to
    /// switch the display between them to find out.
    @ViewBuilder
    private func playhead(of list: Cue) -> some View {
        let cue = model.client.playheads[list.uniqueID]
            .flatMap { list.children.firstCue(withID: $0) }

        Text(cue?.displayNumber ?? "—")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(cue == nil ? .tertiary : .secondary)
            .help(playheadHelp(for: cue))
            .accessibilityLabel(playheadHelp(for: cue))
    }

    private func playheadHelp(for cue: Cue?) -> String {
        guard let cue else { return "This cue list has no playhead set" }
        guard let number = cue.displayNumber else {
            return "Standing by: \(cue.displayName ?? "an unnumbered cue")"
        }
        guard let name = cue.displayName else { return "Standing by: cue \(number)" }
        return "Standing by: cue \(number), \(name)"
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
