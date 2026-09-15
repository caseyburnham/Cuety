import SwiftUI

/// Settings that affect the app as a whole rather than any one view.
struct GeneralSettingsView: View {
    /// The height this pane needs to show everything without scrolling.
    /// Applied by ``SettingsView``; measured, not guessed.
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
                The menu bar item is visible wherever you are — including \
                while another app is in front, and while Cuety is presenting \
                full screen. Its menu can change workspace, disconnect and \
                enter presentation mode without going back to the window.
                """)
            }

            Section {
                Toggle("Badge the Dock icon with the cue number", isOn: Bindable(preferences).showsDockBadge)
            } header: {
                Text("Dock")
            } footer: {
                Text("""
                A badge on Cuety's Dock icon, the way an unread count is \
                shown; a long cue number is shortened to fit. The Dock hides \
                itself while Cuety presents full screen, so this is for \
                glancing down from QLab rather than for the show itself.
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
