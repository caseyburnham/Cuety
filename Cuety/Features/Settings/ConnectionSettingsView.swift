import SwiftUI

struct ConnectionSettingsView: View {
    static let settingsHeight: CGFloat = 640

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
        .task { await model.refreshStoredPasscodes() }
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
        .alert(item: Bindable(model).credentialError) { error in
            Alert(
                title: Text("Keychain Problem"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }


    private var autoConnectSection: some View {
        Section {
            Toggle("Reconnect at launch", isOn: Bindable(preferences).autoConnect)

            LabeledContent("Last workspace") {
                Text(lastWorkspaceDescription)
                    .foregroundStyle(preferences.lastWorkspace == nil ? .tertiary : .secondary)
            }
        }
    }

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


    private var connectionSection: some View {
        Section {
            SteppedField(
                title: "TCP port",
                value: Bindable(preferences).defaultPort,
                range: Preferences.Limits.port,
                format: IntegerFormatStyle<Int>.number.grouping(.never),
                showsStepper: false
            )
            .help("The starting port when you add a server by hand. QLab uses 53000.")

            SteppedField(
                title: "Heartbeat",
                value: Bindable(preferences).heartbeatInterval,
                range: Preferences.Limits.heartbeatInterval,
                format: FloatingPointFormatStyle<Double>.number
                    .precision(.fractionLength(0)),
                unit: "s"
            )
            .help("A shorter heartbeat notices a dropped connection sooner, with more traffic.")

            SteppedField(
                title: "Request timeout",
                value: Bindable(preferences).requestTimeout,
                range: Preferences.Limits.requestTimeout,
                format: FloatingPointFormatStyle<Double>.number
                    .precision(.fractionLength(0)),
                unit: "s"
            )
            .help("How long Cuety waits for QLab to answer a request.")
        } header: {
            Text("Connection")
        }
    }


    private var addedServersSection: some View {
        Section {
            Button("Add Server", systemImage: "plus") {
                model.isAddingServer = true
            }

            if addedServers.isEmpty {
                Text("No custom servers added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addedServers) { server in
                    LabeledContent {
                        Button("Remove", role: .destructive) {
                            model.removeServer(withID: server.id)
                        }
                    } label: {
                        Label(
                            server.address ?? server.name,
                            systemImage: "server.rack"
                        )
                    }
                }
            }
        } header: {
            Text("Added Servers")
        }
    }

    private var addedServers: [QLabServer] {
        model.browser.servers.filter(model.canRemove)
    }


    private var passcodeSection: some View {
        Section {
            if savedPasscodes.isEmpty {
                Text("No passcodes saved for workspaces Cuety can see.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(savedPasscodes, id: \.selection) { entry in
                    // An HStack rather than LabeledContent, which aligns the
                    // button to the first line of the two-line label.
                    HStack {
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

                        Spacer(minLength: 12)

                        Button("Forget") {
                            model.forgetPasscode(for: entry.selection)
                        }
                    }
                }
            }

            Button("Forget All Passcodes…", role: .destructive) {
                isConfirmingForgetAll = true
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("Saved Passcodes")
        } footer: {
            Text("Passcodes saved in Keychain.")
        }
    }

    private struct PasscodeEntry {
        let selection: WorkspaceSelection
        let workspaceName: String
        let serverName: String
    }

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
