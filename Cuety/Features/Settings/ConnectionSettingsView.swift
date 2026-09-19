import SwiftUI

struct ConnectionSettingsView: View {
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
        } footer: {
            Text("When enabled, Cuety looks for the workspace it last connected to at launch and reopens it; choosing a workspace yourself cancels the attempt. Otherwise Cuety connects to nothing until you pick a workspace.")
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
