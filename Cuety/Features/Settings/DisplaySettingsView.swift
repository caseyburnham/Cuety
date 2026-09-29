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

                // Always shown, so the pane keeps its height when the sizing
                // changes; it only applies to custom sizing.
                SteppedField(
                    title: "Custom size",
                    value: Bindable(preferences).customCueNumberSize,
                    range: Preferences.Limits.cueNumberSize,
                    step: 10,
                    format: FloatingPointFormatStyle<Double>.number
                        .precision(.fractionLength(0))
                        .grouping(.never)
                )
                .disabled(preferences.cueNumberSizing != .custom)
            } header: {
                Text("Cue Number Size")
            } footer: {
                Text("""
                Fixed draws every cue in the list at the same size, fitted to the \
                widest number. Custom uses the point size you choose, shrinking \
                only when a number would not fit. As Large as Possible fills the \
                display with each number.
                """)
            }

            Section {
                Picker("Color", selection: Bindable(preferences).playheadAccent) {
                    ForEach(PlayheadAccent.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } header: {
                Text("Playhead")
            } footer: {
                Text("Choose a fixed accent color, or follow the color of the cue currently standing by.")
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
            } header: {
                Text("Layout")
            } footer: {
                Text("""
                Display and Drawer shows the standby cue large with the drawer \
                beneath it. Cue List gives the whole window to the cue list, \
                with the standby cue marked by the playhead arrow.
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
                .font(typography.drawerNumber(
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
        .environment(AppModel())
        .frame(width: SettingsView.width, height: DisplaySettingsView.settingsHeight)
}
