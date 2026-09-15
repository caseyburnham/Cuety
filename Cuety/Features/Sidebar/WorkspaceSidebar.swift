import SwiftUI

/// Workspaces grouped by server, followed by the connected workspace's cue lists.
/// Keeping both at one level avoids nested disclosure rows changing their job.
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
                            // The one row a server with nothing open actually
                            // has, and it had no way to remove that server:
                            // the list's selection menu needs a selectable
                            // row, and this one is deliberately not
                            // selectable. So a machine added at a mistyped
                            // address — the entry most likely to want removing
                            // — could only be reached through the section
                            // header's menu.
                            .contextMenu {
                                removeServerButton(server)
                            }
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
        .listStyle(.sidebar)
        // Let the window's own sidebar material through. A `List` draws an
        // opaque background of its own by default, which sits on top of the
        // translucency the system already provides and flattens it.
        .scrollContentBackground(.hidden)
    }
    // No `.navigationSplitViewColumnWidth` either. The sidebar is an
    // `NSSplitViewItem` now, so its width is `minimumThickness` and
    // `maximumThickness` on that item — and the divider the operator drags is
    // autosaved by the split view rather than reset to an `ideal` on every
    // launch. See ``MainSplitViewController``.
    // No bottom bar. There is no sidebar bottom-bar API for
    // `NavigationSplitView` on macOS — `tabViewSidebarBottomBar` is
    // `TabView`-only and `accessoryBar(id:)` sits under the toolbar — so the
    // one that used to be here was a `safeAreaInset` holding an `HStack` over
    // `.bar`, a hand-built approximation of a control the platform does not
    // offer. Refresh is a toolbar item now, and Add Server is ⌘K in the
    // Connection menu, which is where a command with no live state belongs.

    /// What the sidebar highlights, read straight from the model and stored
    /// nowhere else.
    ///
    /// The highlight means *the cue list driving the display*, and falls back
    /// to the connected workspace only when there is no live list to point at.
    /// A workspace row is an activation target — double-click or the context
    /// menu connects — the way a Finder Favourite is, and its state is already
    /// drawn in the row by the status glyph, so it has no need of the
    /// highlight as well.
    ///
    /// Which is why the setter answers for cue lists and ignores everything
    /// else: a write it does not act on leaves the getter reporting the same
    /// value it did before, so the highlight stays where the model says it
    /// belongs. There was a `selectedRow` here that the getter preferred
    /// unconditionally, and clicking the workspace row you were *already*
    /// connected to changed neither ``AppModel/selection`` nor
    /// ``QLabClient/watchedCueListID`` — so nothing ever cleared it, and the
    /// sidebar stopped saying which cue list the display was following until a
    /// cue list row was clicked again.
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
            // Deliberately not gated on ``AppModel/canConnect``. It used to be
            // — the guard covered this whole setter — so choosing which cue
            // list to watch was refused for as long as a connection attempt
            // was in flight, a question it has nothing to do with.
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
                    // A readout, not a control. There used to be a button here
                    // that swapped itself for a red ✗ on hover — a
                    // hand-rolled affordance macOS has no equivalent of in a
                    // source list, built out of an `onHover` and a hardcoded
                    // 22pt frame, and invisible to anyone not using a mouse.
                    // Disconnect is on the row's context menu, in the
                    // Connection menu with a shortcut, and in the toolbar,
                    // which are the three places macOS would look for it.
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
        // `isConnecting` is a re-entrancy guard for this view's own async
        // action, not a second opinion on availability: a double-click can
        // land twice before `status` becomes `connecting`. Whether the action
        // is *offered* is ``AppModel/canConnect``, everywhere.
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
            // Both the test and the action come from ``AppModel``, so this menu,
            // the one on the status row, and the Connection settings pane cannot
            // disagree about which servers can go or about disconnecting first.
            //
            // No longer disabled by `canConnect`. That blocked removing an
            // unrelated machine for the whole of a connection attempt to a
            // different one — and the attempt is exactly what an operator
            // fixing a mistyped address is trying to get out of.
            Button("Remove Server", role: .destructive) {
                model.removeServer(withID: server.id)
            }
        }
    }

    @ViewBuilder
    private func serverStatus(_ server: QLabServer) -> some View {
        if model.refreshingServerIDs.contains(server.id) {
            // Words only. The spinner for this server is the one in its
            // section header, which is the single place a probe in flight is
            // drawn — this row used to carry a second one, so a server with
            // nothing open spun twice, side by side, for the same probe.
            Text("Looking for workspaces…")
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
        let state = model.client.playheads[list.uniqueID]
        let cue = state?.cueID.flatMap { list.children.firstCue(withID: $0) }

        // One glyph per state, so the column never presents ignorance as an
        // answer. "—" used to cover a failed query and an unasked list as well
        // as an empty one.
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
            // QLab named a cue this list does not contain, which means the
            // tree is behind. A refetch is already on its way.
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
