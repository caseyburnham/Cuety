import SwiftUI

/// Typography and layout choices for the cue display and the drawer.
struct DisplaySettingsView: View {
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

            Section("Cue Drawer") {
                Toggle("Show the drawer", isOn: Binding(
                    get: { preferences.showsDrawer },
                    set: { _ in model.toggleDrawer() }
                ))

                Stepper(
                    "Previous cues: \(preferences.drawerPreviousCount)",
                    value: Bindable(preferences).drawerPreviousCount,
                    in: 0...10
                )
                .monospacedDigit()
                .disabled(!preferences.showsDrawer)

                Stepper(
                    "Upcoming cues: \(preferences.drawerUpcomingCount)",
                    value: Bindable(preferences).drawerUpcomingCount,
                    in: 0...10
                )
                .monospacedDigit()
                .disabled(!preferences.showsDrawer)
            }
        }
        .formStyle(.grouped)
        .task {
            allFamilies = FontCatalog.availableFamilies
            recommendedFamilies = FontCatalog.recommendedFamilies
        }
    }

    /// A live preview of the chosen family, so the choice can be judged on the
    /// glyphs themselves rather than on a font name.
    ///
    /// Set exactly as the drawer sets the cue standing by, since that is where
    /// the family is read at a size close to this one.
    private var sample: some View {
        LabeledContent("Preview") {
            Text(verbatim: "127.5")
                .font(Typography(preferences: preferences)
                    .drawerNumber(size: 40, weight: .semibold))
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
        .frame(width: 520, height: 420)
}
