import SwiftUI

/// Which detail pills appear beneath the cue name, and in what order.
///
/// The list shows every pill including switched-off ones, matching how
/// ``Preferences/pillOrder`` is stored: an operator who arranges the row and
/// then hides one pill should not lose the arrangement.
struct DetailPillSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        let client = model.client

        VStack(spacing: 0) {
            List {
                // The row is written inline on purpose. Moving it into a
                // `-> some View` helper makes the reorderable list render
                // completely empty: `reorderable()` needs to see the row views
                // in the `ForEach` content itself, and an opaque return type
                // hides them from it. Plain rows survive the extraction, so
                // the failure looks unrelated to reordering — it isn't.
                ForEach(preferences.pillOrder) { kind in
                    Toggle(isOn: Binding {
                        preferences.enabledPills.contains(kind)
                    } set: { isEnabled in
                        if isEnabled {
                            preferences.enabledPills.insert(kind)
                        } else {
                            preferences.enabledPills.remove(kind)
                        }

                        // Enabling a pill widens the set of cue keys Cuety
                        // asks for, and nothing else triggers that request
                        // until the playhead next moves. Refetch now so the
                        // pill fills in immediately rather than sitting blank
                        // until the following cue.
                        Task { await client.refreshPlayheadCueDetails() }
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
                                .foregroundStyle(
                                    preferences.enabledPills.contains(kind)
                                        ? Color.accentColor : .secondary
                                )
                        }
                    }
                }
                .reorderable()
            }
            .reorderContainer(for: DetailPillKind.self) { difference in
                apply(difference, to: preferences)
            }

            Divider()

            HStack {
                Text("Drag to reorder. Only enabled pills are requested from QLab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button("Reset") {
                    preferences.pillOrder = DetailPillKind.defaultOrder
                    preferences.enabledPills = DetailPillKind.defaultEnabled
                    Task { await client.refreshPlayheadCueDetails() }
                }
                .help("Restore the default pills and order")
                .disabled(
                    preferences.pillOrder == DetailPillKind.defaultOrder
                        && preferences.enabledPills == DetailPillKind.defaultEnabled
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Reordering

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
        .frame(width: 520, height: 420)
}
