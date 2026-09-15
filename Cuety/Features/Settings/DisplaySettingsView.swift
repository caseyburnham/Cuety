import SwiftUI

/// Typography and layout choices for the cue display and the drawer.
struct DisplaySettingsView: View {
    /// The height this pane needs to show everything without scrolling.
    /// Applied by ``SettingsView``; measured, not guessed.
    static let settingsHeight: CGFloat = 555

    @Environment(AppModel.self) private var model

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            // The system font, in one of two designs and six weights. Choosing
            // an arbitrary installed family was offered here and withdrawn —
            // see ``Typography/font(size:weight:)`` for why it never worked.
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

                // Rows, deliberately, not "previous" and "upcoming" cues. The
                // drawer reads the cue list either side of the playhead; it
                // has no way to know what has been taken or what the next GO
                // will do, so the labels must not imply either.
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

    /// A live preview of the chosen weight and design, so the choice can be
    /// judged on the glyphs themselves rather than on two names.
    ///
    /// The weight comes from ``Typography/cueNumberWeight`` rather than being
    /// fixed here: a Weight picker whose preview ignored it would be the one
    /// control in this pane that showed nothing.
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
