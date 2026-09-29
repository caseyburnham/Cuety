import SwiftUI

struct PasscodeSheet: View {
    let prompt: AppModel.PasscodePrompt

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSubmitting = false
    @State private var attemptError: String?
    @State private var passcode = ""
    @State private var shouldRemember = true
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            SecureField("Passcode", text: $passcode)
                .focused($isFieldFocused)
                .onSubmit(submit)
                .disabled(isSubmitting)

            Toggle("Remember in my Keychain", isOn: $shouldRemember)
                .disabled(isSubmitting)

            if let attemptError {
                Text(attemptError)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.disconnect()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
                Button(isSubmitting ? "Connecting…" : "Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passcode.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFieldFocused = true }
        .interactiveDismissDisabled(isSubmitting)
        // A rejected passcode that cannot be removed is reported here, since
        // this sheet opens over the main window at the same moment.
        .credentialErrorAlert(Bindable(model).credentialError, isActive: model.passcodePrompt != nil)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentPrompt.wasRejected ? "lock.trianglebadge.exclamationmark" : "lock.circle")
                .font(.largeTitle)
                .foregroundStyle(currentPrompt.wasRejected ? .orange : .secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 4) {
                Text(currentPrompt.wasRejected ? "Passcode Not Accepted" : "Passcode Required")
                    .font(.headline)
                Text("Enter the OSC passcode for \(prompt.workspaceName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var currentPrompt: AppModel.PasscodePrompt {
        model.passcodePrompt ?? prompt
    }

    private func submit() {
        guard !passcode.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        attemptError = nil
        Task {
            await model.submitPasscode(passcode, for: prompt, remember: shouldRemember)
            isSubmitting = false
            if model.passcodePrompt != nil {
                if case .needsPasscode = model.client.status {
                    attemptError = nil
                } else {
                    attemptError = model.client.status.detail
                }
                isFieldFocused = true
            }
        }
    }
}

extension View {
    /// Presents a Keychain failure. A presenter that something may cover, such
    /// as the main window beneath the passcode sheet, passes `isActive` so only
    /// the surface on top tries to present.
    func credentialErrorAlert(
        _ error: Binding<AppModel.CredentialError?>, isActive: Bool = true
    ) -> some View {
        alert(
            "Keychain Problem",
            isPresented: Binding(
                get: { isActive && error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }
}

#Preview("Required") {
    PasscodeSheet(
        prompt: .init(
            serverID: "s", workspaceID: "w", workspaceName: "Act One", wasRejected: false
        )
    )
    .environment(AppModel.preview)
}

#Preview("Rejected") {
    PasscodeSheet(
        prompt: .init(
            serverID: "s", workspaceID: "w", workspaceName: "Act One", wasRejected: true
        )
    )
    .environment(AppModel.preview)
}
