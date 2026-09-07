import SwiftUI

/// How Cuety reaches QLab: reconnection, timing, and stored credentials.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var isConfirmingForgetAll = false

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            autoConnectSection
            timingSection
            passcodeSection
        }
        .formStyle(.grouped)
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
            Text("On launch Cuety looks for the workspace it last connected to and reopens it. Choosing a workspace yourself cancels the attempt.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - Timing

    private var timingSection: some View {
        Section {
            LabeledContent("Default port") {
                TextField(
                    "Default port",
                    value: Bindable(preferences).defaultPort,
                    format: .number.grouping(.never)
                )
                .labelsHidden()
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            }

            Stepper(
                "Heartbeat: \(preferences.heartbeatInterval, format: .number.precision(.fractionLength(0)))s",
                value: Bindable(preferences).heartbeatInterval,
                in: 1...60,
                step: 1
            )

            Stepper(
                "Request timeout: \(preferences.requestTimeout, format: .number.precision(.fractionLength(0)))s",
                value: Bindable(preferences).requestTimeout,
                in: 1...60,
                step: 1
            )
        } header: {
            Text("Timing")
        } footer: {
            Text("The port is the starting value when you add a server by hand; QLab's default is 53000. Timing changes apply to the current connection — a shorter heartbeat notices a dropped link sooner at the cost of more traffic.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private struct PasscodeEntry {
        let selection: WorkspaceSelection
        let workspaceName: String
        let serverName: String
    }

    /// Workspaces Cuety can see that have a passcode in the Keychain.
    ///
    /// Derived from the browser rather than from the Keychain: `SecItem`
    /// offers no listing that would give us names to show, so an item for a
    /// machine that has gone away can only be cleared with "Forget All".
    private var savedPasscodes: [PasscodeEntry] {
        model.browser.servers.flatMap { server in
            server.workspaces.compactMap { workspace in
                let selection = WorkspaceSelection(
                    serverID: server.id, workspaceID: workspace.uniqueID
                )
                guard model.passcodes.hasPasscode(
                    serverID: selection.serverID, workspaceID: selection.workspaceID
                ) else { return nil }

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
        .frame(width: 520, height: 460)
}
