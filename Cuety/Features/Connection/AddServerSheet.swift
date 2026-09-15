import SwiftUI

/// Adds a QLab server by address, for the machines Bonjour cannot find.
///
/// Its own view, presented from ``MainWindowView``, rather than a property of
/// ``WorkspaceSidebar``. It lived there while the sidebar had an Add Server
/// button in a bottom bar; now that ⌘K in the Connection menu is the only way
/// in, hanging the sheet — and four helpers only it used — off the sidebar
/// would mean the list of workspaces owned a window that has nothing to do
/// with it.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model

    @State private var host = ""
    @State private var port = ""
    @FocusState private var hostIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Server").font(.headline)
            Text("Enter the address of the Mac running QLab.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Host", text: $host, prompt: Text("192.168.1.10"))
                    .focused($hostIsFocused)
                TextField("Port", text: $port)
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.isAddingServer = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addServer)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedHost.isEmpty || parsedPort == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            // Seeded here rather than at the declarations: the sheet is built
            // once and shown repeatedly, so a second ⌘K would otherwise arrive
            // with whatever was typed the first time.
            host = ""
            port = String(model.preferences.defaultPort)
            hostIsFocused = true
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed port, or `nil` when Add should stay disabled.
    ///
    /// Bounded by ``Preferences/Limits/port`` rather than by `UInt16` parsing
    /// alone, so the field and the stored default agree on what a port is.
    private var parsedPort: UInt16? {
        guard let value = Int(port), Preferences.Limits.port.contains(value) else { return nil }
        return UInt16(value)
    }

    private func addServer() {
        guard !trimmedHost.isEmpty, let parsedPort else { return }
        let server = model.browser.addManualServer(host: trimmedHost, port: parsedPort)
        model.isAddingServer = false
        // Asks this one server what it has open, leaving the others and the
        // live connection alone — which a full refresh would not. A server
        // just typed in has never been contacted, so without this it would sit
        // at "Check for Workspaces" until something else asked.
        Task { await model.refreshWorkspaces(onServerWithID: server.id) }
    }
}

#Preview {
    AddServerSheet()
        .environment(AppModel())
}
