import SwiftUI

struct GeneralSettingsView: View {
    static let settingsHeight: CGFloat = 535

    @Environment(AppModel.self) private var model

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Bindable(model.preferences).appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } footer: {
                Text("Automatic follows the system setting.")
            }

            Section {
                Toggle("Keep the display awake", isOn: Binding(
                    get: { model.preferences.keepsDisplayAwake },
                    set: { _ in model.toggleKeepAwake() }
                ))

                Toggle("Performance mode", isOn: Bindable(preferences).performanceMode)
            } footer: {
                Text("Disables visual effects.")
            }

            Section {
                Toggle("Show Cuety in the menu bar", isOn: Bindable(preferences).showsMenuBarExtra)

                Picker("Show", selection: Bindable(preferences).menuBarReadout) {
                    ForEach(MenuBarReadout.allCases) { readout in
                        Text(readout.title).tag(readout)
                    }
                }
                .disabled(!preferences.showsMenuBarExtra)
                .help(preferences.menuBarReadout.detail)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("""
                Display the standby cue number, connection status, or heartbeat in the menu bar.
                """)
            }

            Section {
                Toggle("Badge the Dock icon with the cue number", isOn: Bindable(preferences).showsDockBadge)
            } header: {
                Text("Dock")
            } footer: {
                Text("""
                Display the standby cue number in a Dock icon badge.
                """)
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
