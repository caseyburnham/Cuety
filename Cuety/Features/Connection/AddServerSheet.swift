import SwiftUI

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
            host = ""
            port = String(model.preferences.defaultPort)
            hostIsFocused = true
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPort: UInt16? {
        guard let value = Int(port), Preferences.Limits.port.contains(value) else { return nil }
        return UInt16(value)
    }

    private func addServer() {
        guard !trimmedHost.isEmpty, let parsedPort else { return }
        let server = model.browser.addManualServer(host: trimmedHost, port: parsedPort)
        model.isAddingServer = false
        Task { await model.refreshWorkspaces(onServerWithID: server.id) }
    }
}

#Preview {
    AddServerSheet()
        .environment(AppModel())
}
