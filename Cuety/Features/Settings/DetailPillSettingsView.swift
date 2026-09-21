import SwiftUI

struct DetailPillSettingsView: View {
    static let settingsHeight: CGFloat = 625

    @Environment(AppModel.self) private var model

    private var inlineOrder: [DetailPillKind] {
        model.preferences.pillOrder.filter { $0 != .notes }
    }

    var body: some View {
        let preferences = model.preferences
        let client = model.client

        List {
            Section {
                Picker("Size", selection: Bindable(preferences).pillSize) {
                    ForEach(PillSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show the cue type name", isOn: Bindable(preferences).showsCueTypeLabel)
            } header: {
                Text("Appearance")
            } footer: {
                Text("With the name off, the cue type pill keeps its glyph alone.")
            }

            Section("Pills") {
                ForEach(inlineOrder) { kind in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding {
                            preferences.enabledPills.contains(kind) || kind.isAlwaysVisible
                        } set: { isEnabled in
                            if isEnabled {
                                preferences.enabledPills.insert(kind)
                            } else {
                                preferences.enabledPills.remove(kind)
                            }

                            Task { await client.refreshPlayheadCueDetails(force: true) }
                        }) {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(kind.title)
                                    Text(kind.settingsDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: kind.systemImage)
                                    .rotationEffect(kind.glyphRotation)
                                    .foregroundStyle(
                                        preferences.enabledPills.contains(kind)
                                            || kind.isAlwaysVisible
                                            ? Color.accentColor : .secondary
                                    )
                            }
                        }
                        .disabled(kind.isAlwaysVisible)

                        Spacer(minLength: 10)

                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .reorderable()
            }

            Section("Notes") {
                Toggle(isOn: Binding {
                    preferences.enabledPills.contains(.notes)
                } set: { isEnabled in
                    if isEnabled {
                        preferences.enabledPills.insert(.notes)
                    } else {
                        preferences.enabledPills.remove(.notes)
                    }
                    Task { await client.refreshPlayheadCueDetails(force: true) }
                }) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(DetailPillKind.notes.title)
                            Text(DetailPillKind.notes.settingsDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: DetailPillKind.notes.systemImage)
                            .foregroundStyle(
                                preferences.enabledPills.contains(.notes)
                                    ? Color.accentColor : .secondary
                            )
                    }
                }
            }
        }
        .reorderContainer(for: DetailPillKind.self) { difference in
            apply(difference, to: preferences)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Drag to reorder. Only enabled pills are requested from QLab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button("Reset") {
                    preferences.pillOrder = DetailPillKind.defaultOrder
                    preferences.enabledPills = DetailPillKind.defaultEnabled
                    preferences.pillSize = .default
                    preferences.showsCueTypeLabel = true
                    Task { await client.refreshPlayheadCueDetails(force: true) }
                }
                .help("Restore the default pills, order, and size")
                .disabled(
                    preferences.pillOrder == DetailPillKind.defaultOrder
                        && preferences.enabledPills == DetailPillKind.defaultEnabled
                        && preferences.pillSize == .default
                        && preferences.showsCueTypeLabel
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }


    private func apply(
        _ difference: ReorderDifference<DetailPillKind.ID, ReorderableSingleCollectionIdentifier>,
        to preferences: Preferences
    ) {
        var order = preferences.pillOrder
        let moving = difference.sources.compactMap { id in
            order.first { $0.id == id }
        }
        guard !moving.isEmpty else { return }

        order.removeAll(where: moving.contains)

        switch difference.destination.position {
        case .before(let targetID):
            if let index = order.firstIndex(where: { $0.id == targetID }) {
                order.insert(contentsOf: moving, at: index)
            } else {
                order.append(contentsOf: moving)
            }
        case .end:
            order.append(contentsOf: moving)
        }

        preferences.pillOrder = order
    }
}

#Preview {
    DetailPillSettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: DetailPillSettingsView.settingsHeight)
}
