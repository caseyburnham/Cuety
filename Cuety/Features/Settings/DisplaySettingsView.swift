import SwiftUI

struct DisplaySettingsView: View {
    static let settingsHeight: CGFloat = 555

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
                Toggle("Show the cue name", isOn: Bindable(preferences).showsCueName)
            } footer: {
                Text("The name appears beneath the number. Turning it off gives the number the whole window.")
            }

            Section {
                Toggle("Show the drawer", isOn: Binding(
                    get: { preferences.showsDrawer },
                    set: { _ in model.toggleDrawer() }
                ))

                SteppedField(
                    title: "Rows above the playhead",
                    value: Bindable(preferences).drawerRowsAboveCount,
                    range: Preferences.Limits.drawerRows,
                    format: IntegerFormatStyle<Int>.number.grouping(.never)
                )
                .disabled(!preferences.showsDrawer)

                SteppedField(
                    title: "Rows below the playhead",
                    value: Bindable(preferences).drawerRowsBelowCount,
                    range: Preferences.Limits.drawerRows,
                    format: IntegerFormatStyle<Int>.number.grouping(.never)
                )
                .disabled(!preferences.showsDrawer)
            } header: {
                Text("Cue Drawer")
            } footer: {
                Text("""
                The drawer shows the watched cue list either side of the playhead. \
                A group counts as one row; the cues inside it are not listed. \
                Near either end of the list, rows one side has run out of are \
                shown on the other instead, so the drawer keeps its size — \
                unless that side is set to none.
                """)
            }
        }
        .formStyle(.grouped)
    }

    private var sample: some View {
        let typography = Typography(preferences: preferences)

        return LabeledContent("Preview") {
            Text(verbatim: "127.5")
                .font(typography.drawerNumber(
                    size: 40, weight: typography.cueNumberWeight
                ))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Sample cue number at the selected weight")
        }
    }
}

#Preview {
    DisplaySettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: DisplaySettingsView.settingsHeight)
}
