import SwiftUI

struct DisplaySettingsView: View {
    static let settingsHeight: CGFloat = 650

    @Environment(AppModel.self) private var model

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Section("Cue Number") {
                Picker("Weight", selection: Bindable(preferences).fontWeight) {
                    ForEach(FontWeightChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                Toggle("Use the rounded system font", isOn: Bindable(preferences).usesRoundedSystemFont)
                    .help("Switches the system font to its rounded design.")

                sample
            }

            Section {
                Picker("Size", selection: Bindable(preferences).cueNumberSizing) {
                    ForEach(CueNumberSizing.allCases) { sizing in
                        Text(sizing.title).tag(sizing)
                    }
                }

            } header: {
                Text("Cue Number Size")
            }

            Section {
                Picker("Layout", selection: Binding(
                    get: { preferences.cueLayout },
                    set: { model.setCueLayout($0) }
                )) {
                    ForEach(CueLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage).tag(layout)
                    }
                }

                Toggle("Show playhead", isOn: Bindable(preferences).showsPlayhead)
                    .disabled(preferences.cueLayout != .list)
                    .help("Shows the arrow marking the standby cue in Cue List layout.")

                Picker("Playhead color", selection: Bindable(preferences).playheadAccent) {
                    ForEach(PlayheadAccent.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("""
                Display and Drawer shows the standby cue large with a cue drawer 
                beneath it. Cue List gives the whole window to the cue list.
                """)
            }
        }
        .formStyle(.grouped)
    }

    private var sample: some View {
        let typography = Typography(preferences: preferences)

        // An HStack rather than LabeledContent, which lines the label up with
        // the large number's baseline instead of its center.
        return HStack {
            Text("Preview")

            Spacer(minLength: 12)

            Text(verbatim: "127.5")
                .font(typography.font(
                    size: 40, weight: typography.cueNumberWeight
                ))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Sample cue number at the selected weight")
        }
    }
}

#Preview {
    DisplaySettingsView()
        .environment(AppModel.preview)
        .frame(width: SettingsView.width, height: DisplaySettingsView.settingsHeight)
}
