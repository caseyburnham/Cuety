import SwiftUI

struct DetailPillSettingsView: View {
    static let settingsHeight: CGFloat = 720

    @Environment(AppModel.self) private var model

    private var preferences: Preferences { model.preferences }

    private var isAtDefaults: Bool {
        preferences.enabledPills == DetailPillKind.defaultEnabled
            && preferences.pillSize == .default
            && preferences.showsCueTypeLabel
            && preferences.showsCueName
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Show the cue name", isOn: Bindable(preferences).showsCueName)

                Toggle("Show the cue type name", isOn: Bindable(preferences).showsCueTypeLabel)
                    .help("With the name off, the cue type pill keeps its icon alone.")

                Picker("Pill size", selection: Bindable(preferences).pillSize) {
                    ForEach(PillSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
            }

            Section {
                ForEach(DetailPillKind.defaultOrder.filter { $0 != .notes && !$0.isAlwaysVisible }) { kind in
                    pillToggle(kind)
                }
            } header: {
                Text("Pills")
            }

            Section {
                pillToggle(.notes)
            }

            Section {
                HStack {
                    Spacer()

                    Button("Restore Defaults") {
                        preferences.enabledPills = DetailPillKind.defaultEnabled
                        preferences.pillSize = .default
                        preferences.showsCueTypeLabel = true
                        preferences.showsCueName = true
                        refreshDetails()
                    }
                    .disabled(isAtDefaults)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pillToggle(_ kind: DetailPillKind) -> some View {
        Toggle(isOn: Binding {
            preferences.enabledPills.contains(kind)
        } set: { isEnabled in
            if isEnabled {
                preferences.enabledPills.insert(kind)
            } else {
                preferences.enabledPills.remove(kind)
            }
            refreshDetails()
        }) {
            Label {
                Text(kind.title)
                Text(kind.settingsDescription)
            } icon: {
                Image(systemName: kind.systemImage)
                    .rotationEffect(kind.glyphRotation)
                    .foregroundStyle(.secondary)
                    // A fixed width keeps every title on the same leading edge.
                    .frame(width: 20)
            }
        }
    }

    private func refreshDetails() {
        let client = model.client
        Task { await client.refreshPlayheadCueDetails(force: true) }
    }

}

#Preview {
    DetailPillSettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: DetailPillSettingsView.settingsHeight)
}
