import SwiftUI

/// Settings that affect the app as a whole rather than any one view.
struct GeneralSettingsView: View {
    /// The height this pane needs to show everything without scrolling.
    /// Applied by ``SettingsView``; measured, not guessed.
    static let settingsHeight: CGFloat = 220

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Bindable(model.preferences).appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } footer: {
                // Section footers in a grouped Form are already set as
                // secondary caption text; restyling them by hand only risks
                // disagreeing with the system.
                Text("Automatic follows the system setting. A dark display is usually the right choice in a booth.")
            }

            Section {
                // Routed through the model rather than bound straight to the
                // preference: flipping this has to tell the sleep blocker as
                // well, or the setting and the actual assertion drift apart.
                Toggle("Keep the display awake", isOn: Binding(
                    get: { model.preferences.keepsDisplayAwake },
                    set: { _ in model.toggleKeepAwake() }
                ))
            } footer: {
                Text("Prevents the screen from sleeping while Cuety is running, so the cue display stays visible through a long act.")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: GeneralSettingsView.settingsHeight)
}
