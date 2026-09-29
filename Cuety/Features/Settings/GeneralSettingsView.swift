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
                    set: { model.setKeepsDisplayAwake($0) }
                ))

                Toggle("Performance mode", isOn: Bindable(preferences).performanceMode)
            } footer: {
                Text("Performance mode reduces display animations and effects.")
            }

#if os(macOS)
            Section("Menu Bar") {
                Toggle("Show Cuety in the menu bar", isOn: Bindable(preferences).showsMenuBarExtra)

                Picker("Show", selection: Bindable(preferences).menuBarReadout) {
                    ForEach(MenuBarReadout.allCases) { readout in
                        Text(readout.title).tag(readout)
                    }
                }
                .disabled(!preferences.showsMenuBarExtra)
                .help(preferences.menuBarReadout.detail)
            }

            Section("Dock") {
                Toggle("Badge the Dock icon with the cue number", isOn: Bindable(preferences).showsDockBadge)
            }
#endif
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: GeneralSettingsView.settingsHeight)
}
