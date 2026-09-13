import SwiftUI

/// Typography and layout choices for the cue display and the drawer.
struct DisplaySettingsView: View {
    /// The height this pane needs to show everything without scrolling.
    /// Applied by ``SettingsView``; measured, not guessed.
    static let settingsHeight: CGFloat = 585

    @Environment(AppModel.self) private var model

    /// Loaded once in `task` rather than read in `body`: building the catalogue
    /// walks every installed family and probes each for a digit glyph, which is
    /// far too much work to repeat on every view update.
    @State private var allFamilies: [String] = []
    @State private var recommendedFamilies: [String] = []

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Section("Cue Number") {
                Picker("Font", selection: Bindable(preferences).fontFamily) {
                    Text("System").tag(String?.none)

                    if !recommendedFamilies.isEmpty {
                        Section("Suited to Large Numbers") {
                            ForEach(recommendedFamilies, id: \.self) { family in
                                Text(family).tag(String?.some(family))
                            }
                        }
                    }

                    if !allFamilies.isEmpty {
                        Section("All Fonts") {
                            ForEach(allFamilies, id: \.self) { family in
                                Text(family).tag(String?.some(family))
                            }
                        }
                    }
                }

                Picker("Weight", selection: Bindable(preferences).fontWeight) {
                    ForEach(FontWeightChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                // Only meaningful for the system font — a custom family brings
                // its own shapes, so there is no rounded variant to opt into.
                Toggle("Use the rounded system font", isOn: Bindable(preferences).usesRoundedSystemFont)
                    .disabled(preferences.fontFamily != nil)
                    .help(
                        preferences.fontFamily == nil
                            ? "Switches the system font to its rounded design."
                            : "Only applies when the cue number uses the system font."
                    )

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
                A group counts as one row; the cues inside it are not listed.
                """)
            }
        }
        .formStyle(.grouped)
        .task {
            allFamilies = FontCatalog.availableFamilies
            recommendedFamilies = FontCatalog.recommendedFamilies
        }
    }

    /// A live preview of the chosen family and weight, so the choice can be
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
                .accessibilityLabel("Sample cue number in the selected font")
        }
    }
}

#Preview {
    DisplaySettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: DisplaySettingsView.settingsHeight)
}
