import SwiftUI

/// Prompts for a workspace passcode.
///
/// The rejection copy is load-bearing: QLab introduces a progressively longer
/// delay after repeated bad passcodes, so telling the operator to slow down is
/// more useful than letting them hammer the button and conclude Cuety is broken.
struct PasscodeSheet: View {
    let prompt: AppModel.PasscodePrompt

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var passcode = ""
    @State private var shouldRemember = true
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            SecureField("Passcode", text: $passcode)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(submit)

            Toggle("Remember in my Keychain", isOn: $shouldRemember)
                .font(.callout)

            if prompt.wasRejected {
                Label {
                    Text("QLab delays repeated attempts, so wait a moment before trying again.")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    model.passcodePrompt = nil
                    model.disconnect()
                    dismiss()
                }
                Spacer()
                Button("Connect", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(passcode.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFieldFocused = true }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: prompt.wasRejected ? "lock.trianglebadge.exclamationmark" : "lock.circle")
                .font(.largeTitle)
                .foregroundStyle(prompt.wasRejected ? .orange : .secondary)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.wasRejected ? "Passcode Not Accepted" : "Passcode Required")
                    .font(.headline)
                Text("\(prompt.workspaceName) is protected by an OSC passcode.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        guard !passcode.isEmpty else { return }
        let entered = passcode

        // Only persist when asked. A passcode typed for a one-off connection to
        // someone else's machine shouldn't linger in the Keychain.
        if shouldRemember {
            Task { await model.submitPasscode(entered, for: prompt) }
        } else {
            model.passcodePrompt = nil
            Task {
                await model.connectOnce(withPasscode: entered, for: prompt)
            }
        }
        dismiss()
    }
}

#Preview("Required") {
    PasscodeSheet(
        prompt: .init(
            serverID: "s", workspaceID: "w", workspaceName: "Act One", wasRejected: false
        )
    )
    .environment(AppModel())
}

#Preview("Rejected") {
    PasscodeSheet(
        prompt: .init(
            serverID: "s", workspaceID: "w", workspaceName: "Act One", wasRejected: true
        )
    )
    .environment(AppModel())
}
