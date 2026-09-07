import SwiftUI

/// Settings that affect the app as a whole rather than any one view.
struct GeneralSettingsView: View {
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
                Text("Automatic follows the system setting. A dark display is usually the right choice in a booth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppModel())
        .frame(width: 520, height: 320)
}
