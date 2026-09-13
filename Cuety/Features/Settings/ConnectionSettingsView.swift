import SwiftUI

/// How Cuety reaches QLab: reconnection, the connection itself, and stored
/// credentials.
struct ConnectionSettingsView: View {
    /// The height this pane needs to show everything without scrolling.
    ///
    /// Sized for one added server and an empty Saved Passcodes section, which
    /// are the two parts of this pane that grow: a Mac with several added
    /// servers or several protected workspaces will still scroll, and no fixed
    /// height can prevent that.
    static let settingsHeight: CGFloat = 720

    @Environment(AppModel.self) private var model

    @State private var isConfirmingForgetAll = false

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            autoConnectSection
            connectionSection
            addedServersSection
            passcodeSection
        }
        .formStyle(.grouped)
        // The Keychain is only consulted when this pane appears, not on every
        // redraw. What Cuety can see changes as servers come and go, so the
        // set is rebuilt here and then maintained by the actions that change
        // it.
        .task { model.refreshStoredPasscodes() }
        .confirmationDialog(
            "Forget every saved passcode?",
            isPresented: $isConfirmingForgetAll
        ) {
            Button("Forget All", role: .destructive) {
                model.forgetAllPasscodes()
            }
        } message: {
            Text("Cuety will ask for a passcode the next time it connects to a protected workspace.")
        }
        // Keychain writes used to be discarded, so a Forget that failed looked
        // like a Forget that worked.
        .alert(item: Bindable(model).credentialError) { error in
            Alert(
                title: Text("Keychain Problem"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Auto-connect

    private var autoConnectSection: some View {
        Section {
            Toggle("Reconnect at launch", isOn: Bindable(preferences).autoConnect)

            LabeledContent("Last workspace") {
                Text(lastWorkspaceDescription)
                    .foregroundStyle(preferences.lastWorkspace == nil ? .tertiary : .secondary)
            }
        } footer: {
            Text("When enabled, Cuety looks for the workspace it last connected to at launch and reopens it; choosing a workspace yourself cancels the attempt. Otherwise Cuety connects to nothing until you pick a workspace.")
        }
    }

    /// Names the remembered workspace when it can still be resolved, and falls
    /// back to the stored identifier when the server is not currently visible —
    /// which is itself useful to know.
    private var lastWorkspaceDescription: String {
        guard let last = preferences.lastWorkspace else { return "None" }
        guard let server = model.browser.server(withID: last.serverID) else {
            return "Not currently on the network"
        }
        guard let workspace = server.workspaces.first(where: { $0.uniqueID == last.workspaceID })
        else {
            return "Not open on \(server.name)"
        }
        return "\(workspace.displayName) — \(server.name)"
    }

    // MARK: - Connection

    /// The port and the two intervals, all three as fields rather than as
    /// stepped prose.
    ///
    /// The port was already editable and did not look it: a `TextField` with
    /// no bezel inside a `LabeledContent` reads as a value Cuety is reporting.
    /// ``SteppedField`` borders it, which is the whole difference.
    private var connectionSection: some View {
        Section {
            SteppedField(
                title: "TCP port",
                value: Bindable(preferences).defaultPort,
                range: Preferences.Limits.port,
                format: IntegerFormatStyle<Int>.number.grouping(.never),
                // Nobody steps to a port. It is five digits that get typed.
                showsStepper: false
            )

            SteppedField(
                title: "Heartbeat",
                value: Bindable(preferences).heartbeatInterval,
                range: Preferences.Limits.heartbeatInterval,
                format: FloatingPointFormatStyle<Double>.number
                    .precision(.fractionLength(0)),
                unit: "s"
            )

            SteppedField(
                title: "Request timeout",
                value: Bindable(preferences).requestTimeout,
                range: Preferences.Limits.requestTimeout,
                format: FloatingPointFormatStyle<Double>.number
                    .precision(.fractionLength(0)),
                unit: "s"
            )
        } header: {
            Text("Connection")
        } footer: {
            Text("The port is the starting value when you add a server by hand; QLab's default is 53000. The two intervals apply to the current connection — a shorter heartbeat notices a dropped link sooner at the cost of more traffic.")
        }
    }

    // MARK: - Added servers

    /// Every server the operator typed in, each with a way to remove it.
    ///
    /// Removal existed before this, in two sidebar context menus, and between
    /// them they missed the case that matters: a server added at an address
    /// Cuety cannot reach has no workspace rows, and the only row it does have
    /// is not selectable — so there was nothing to right-click but the section
    /// header. The mistyped address was the hardest entry in the app to get
    /// rid of.
    ///
    /// A plain list with a button beside each row, alongside Saved Passcodes,
    /// which is the same shape of problem and already solved this way.
    private var addedServersSection: some View {
        Section {
            if addedServers.isEmpty {
                Text("No servers added by hand.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addedServers) { server in
                    LabeledContent {
                        Button("Remove", role: .destructive) {
                            model.removeServer(withID: server.id)
                        }
                    } label: {
                        // The address, not the name: they are the same string
                        // for a manual entry except that the address carries
                        // the port, and the port is half of what identifies a
                        // server — two QLabs on one machine are two servers.
                        Label(
                            server.address ?? server.name,
                            systemImage: "server.rack"
                        )
                    }
                }
            }
        } header: {
            Text("Added Servers")
        } footer: {
            Text("Add servers from the sidebar or the Connection menu. This Mac and machines found on your network can't be removed.")
        }
    }

    /// The manually added servers, which is every server minus the ones Cuety
    /// found for itself and the built-in entry for this Mac.
    private var addedServers: [QLabServer] {
        model.browser.servers.filter(model.canRemove)
    }

    // MARK: - Passcodes

    private var passcodeSection: some View {
        Section {
            if savedPasscodes.isEmpty {
                Text("No passcodes saved for workspaces Cuety can see.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(savedPasscodes, id: \.selection) { entry in
                    LabeledContent {
                        Button("Forget") {
                            model.forgetPasscode(for: entry.selection)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.workspaceName)
                                Text(entry.serverName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key.fill")
                        }
                    }
                }
            }

            Button("Forget All Passcodes…", role: .destructive) {
                isConfirmingForgetAll = true
            }
        } header: {
            Text("Saved Passcodes")
        } footer: {
            Text("Passcodes live in your Keychain, one per workspace. Only workspaces currently on the network can be listed individually.")
        }
    }

    private struct PasscodeEntry {
        let selection: WorkspaceSelection
        let workspaceName: String
        let serverName: String
    }

    /// Workspaces Cuety can see that have a passcode stored.
    ///
    /// Names come from the browser, but *membership* comes from
    /// ``AppModel/storedPasscodeSelections`` rather than from the Keychain
    /// directly. That is the whole fix: asking `SecItem` from a computed view
    /// property gave Forget nothing to invalidate, so removing a credential
    /// left its row on screen until something unrelated redrew the window.
    ///
    /// `SecItem` still offers no listing that would give names to show, so an
    /// item belonging to a machine that has gone away can only be cleared with
    /// Forget All.
    private var savedPasscodes: [PasscodeEntry] {
        model.browser.servers.flatMap { server in
            server.workspaces.compactMap { workspace in
                let selection = WorkspaceSelection(
                    serverID: server.id, workspaceID: workspace.uniqueID
                )
                guard model.storedPasscodeSelections.contains(selection) else { return nil }

                return PasscodeEntry(
                    selection: selection,
                    workspaceName: workspace.displayName,
                    serverName: server.name
                )
            }
        }
    }
}

#Preview {
    ConnectionSettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: ConnectionSettingsView.settingsHeight)
}
