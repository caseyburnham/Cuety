import SwiftUI

/// Workspaces grouped by server, followed by the connected workspace's cue lists.
/// Keeping both at one level avoids nested disclosure rows changing their job.
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAddingServer = false
    @State private var newHost = ""
    @State private var newPort = String(QLabServer.defaultPort)
    @State private var isConnecting = false
    @State private var selectedRow: Selection?
    @FocusState private var hostIsFocused: Bool

    private enum Selection: Hashable {
        case workspace(WorkspaceSelection)
        case cueList(String)
    }

    var body: some View {
        List(selection: sidebarSelection) {
            ForEach(model.browser.manualServers + model.browser.bonjourServers) { server in
                Section {
                    ForEach(server.workspaces) { workspace in
                        workspaceRow(workspace, on: server)
                    }
                    if server.workspaces.isEmpty {
                        serverStatus(server)
                            .selectionDisabled()
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(server.name)
                        // In the header, not in the rows: the "Looking for
                        // workspaces…" row below only exists when a server has
                        // *no* workspaces, so a server that already listed one
                        // gave no sign of being re-probed at all — which read
                        // as Refresh having skipped it.
                        if model.refreshingServerIDs.contains(server.id) {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.blurReplace)
                                .accessibilityLabel("Looking for workspaces on \(server.name)")
                        }
                    }
                    .animation(
                        reduceMotion ? nil : Motion.status,
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
                // Offered for any session Cuety is holding open, not just a
                // live one: a reconnect loop is exactly the situation where
                // the operator needs a way to call it off.
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
        .onChange(of: model.selection) { selectedRow = nil }
        .onChange(of: model.client.watchedCueListID) { selectedRow = nil }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    newHost = ""
                    newPort = String(model.preferences.defaultPort)
                    isAddingServer = true
                } label: {
                    Label("Add Server…", systemImage: "plus")
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    // Magic-replaced into an indicator rather than spun. A
                    // slowly rotating arrow reads as a stuck animation, and
                    // says nothing about how long there is to wait.
                    //
                    // `progress.indicator` is a symbol, which is what makes
                    // this a real morph: a `ProgressView` is an
                    // `NSProgressIndicator` and has nothing for `.replace` to
                    // operate on. It is also the glyph `ConnectionStatus`
                    // already uses for `connecting`, with the same effect on
                    // it — so "Cuety is working" looks the same wherever it
                    // appears.
                    Label {
                        Text("Refresh Everything")
                    } icon: {
                        Image(
                            systemName: model.isRefreshing
                                ? "progress.indicator"
                                : "arrow.clockwise"
                        )
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                        .symbolEffect(
                            .variableColor.iterative,
                            isActive: model.isRefreshing && !reduceMotion
                        )
                    }
                }
                .animation(reduceMotion ? nil : Motion.status, value: model.isRefreshing)
                .labelStyle(.iconOnly)
                .disabled(!model.canRefresh)
                // Still enabled while refreshing: pressing it again starts over
                // rather than being ignored.
                .help(model.isRefreshing
                    ? "Searching. Click again to start over."
                    : "Refresh available workspaces and rebuild the current QLab connection.")
            }
            .padding(10)
            .background(.bar)
        }
        .sheet(isPresented: $isAddingServer) {
            addServerSheet
        }
    }

    private var sidebarSelection: Binding<Selection?> {
        Binding {
            if let selectedRow { return selectedRow }
            if model.client.status.hasLiveData, let id = model.client.watchedCueListID {
                return .cueList(id)
            }
            return model.selection.map(Selection.workspace)
        } set: { selection in
            guard let selection, !isConnecting, model.canConnect else { return }
            selectedRow = selection
            switch selection {
            case .workspace:
                break
            case .cueList(let id):
                guard id != model.client.watchedCueListID else { return }
                withAnimation(reduceMotion ? nil : Motion.cueChange) {
                    model.client.watchedCueListID = id
                }
                Task { await model.client.refreshPlayheadCueDetails() }
            }
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
                    } else if model.client.isSessionActive {
                        // Includes a session that is retrying: the glyph shows
                        // what is happening and hovering it offers the way out.
                        WorkspaceDisconnectButton(status: model.client.status) { model.disconnect() }
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
        // `isConnecting` is a re-entrancy guard for this view's own async
        // action, not a second opinion on availability: a double-click can
        // land twice before `status` becomes `connecting`. Whether the action
        // is *offered* is ``AppModel/canConnect``, everywhere.
        guard !isConnecting, model.canConnect else { return }
        guard selection != model.selection || !model.client.status.hasLiveData else { return }
        selectedRow = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            await model.connect(to: selection)
        }
    }

    @ViewBuilder
    private func removeServerButton(_ server: QLabServer) -> some View {
        if server.source == .manual, server.id != QLabServer.localhost().id {
            Button("Remove Server", role: .destructive) {
                if model.selection?.serverID == server.id { model.disconnect() }
                model.browser.removeManualServer(id: server.id)
            }
            // Removing a server can disconnect, so it answers to the same
            // definition rather than inventing its own.
            .disabled(!model.canConnect)
        }
    }

    @ViewBuilder
    private func serverStatus(_ server: QLabServer) -> some View {
        if model.refreshingServerIDs.contains(server.id) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Looking for workspaces…")
            }
            .foregroundStyle(.secondary)
        } else if let error = server.lastError {
            Label("Unable to Reach QLab", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help(error)
        } else if !server.hasBeenProbed {
            // Distinct from "No Open Workspaces": Cuety hasn't asked yet, and
            // saying otherwise would report a fact it doesn't have.
            Button("Check for Workspaces") { probeWorkspaces(on: server) }
                .buttonStyle(.link)
                .help("Cuety hasn't contacted \(server.name) yet.")
        } else {
            Text("No Open Workspaces")
                .foregroundStyle(.secondary)
        }
    }

    private func cueListRow(_ list: Cue) -> some View {
        let cue = model.client.playheads[list.uniqueID]
            .flatMap { list.children.firstCue(withID: $0) }
        let playheadDescription = cue.map {
            "Standing by: \($0.displayNumber ?? "Unnumbered cue"), \($0.displayName ?? "Untitled")"
        } ?? "No cue standing by"

        return Label {
            HStack {
                Text(list.displayName ?? "Untitled Cue List")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(cue?.displayNumber ?? "—")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(playheadDescription)
                    .accessibilityLabel(playheadDescription)
            }
        } icon: {
            Image(systemName: "list.triangle")
        }
        .tag(Selection.cueList(list.uniqueID))
        .help(list.displayName ?? "Untitled Cue List")
        .accessibilityHint("Watches this cue list's playhead")
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Server").font(.headline)
            Text("Enter the address of the Mac running QLab.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Host", text: $newHost, prompt: Text("192.168.1.10"))
                    .focused($hostIsFocused)
                TextField("Port", text: $newPort)
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAddingServer = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addServer)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || port == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { hostIsFocused = true }
    }

    private var host: String { newHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? {
        guard let value = UInt16(newPort), value > 0 else { return nil }
        return value
    }

    private func addServer() {
        guard !host.isEmpty, let port else { return }
        let server = model.browser.addManualServer(host: host, port: port)
        isAddingServer = false
        probeWorkspaces(on: server)
    }

    /// Asks a single server what it has open, leaving the other servers and the
    /// live connection alone — which a full refresh would not.
    ///
    /// No local in-flight set any more. ``AppModel`` owns probe bookkeeping —
    /// the indicator and which probe's answer wins — so this view kept a
    /// second copy of state it did not own, and the two had already drifted
    /// into showing spinners under different conditions.
    private func probeWorkspaces(on server: QLabServer) {
        Task { await model.refreshWorkspaces(onServerWithID: server.id) }
    }
}

private struct WorkspaceDisconnectButton: View {
    let status: ConnectionStatus
    let disconnect: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: disconnect) {
            Image(systemName: isHovering ? "xmark.circle.fill" : status.systemImage)
                .foregroundStyle(isHovering ? .red : status.tint)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : Motion.status, value: isHovering)
        .help("Disconnect")
        .accessibilityLabel("Disconnect from workspace")
    }
}
