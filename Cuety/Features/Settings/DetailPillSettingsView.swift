import SwiftUI

/// Which detail pills appear beneath the cue name, and in what order.
///
/// The list shows every pill including switched-off ones, matching how
/// ``Preferences/pillOrder`` is stored: an operator who arranges the row and
/// then hides one pill should not lose the arrangement.
struct DetailPillSettingsView: View {
    @Environment(AppModel.self) private var model

    /// The pills whose order the display actually honours.
    ///
    /// `pillOrder` still holds every pill, notes included, so nothing about
    /// stored preferences changes and an operator who switches notes off and
    /// on again keeps their arrangement.
    private var inlineOrder: [DetailPillKind] {
        model.preferences.pillOrder.filter { $0 != .notes }
    }

    var body: some View {
        let preferences = model.preferences
        let client = model.client

        List {
            // The row is written inline on purpose. Moving it into a
            // `-> some View` helper makes the reorderable list render
            // completely empty: `reorderable()` needs to see the row views
            // in the `ForEach` content itself, and an opaque return type
            // hides them from it. Plain rows survive the extraction, so
            // the failure looks unrelated to reordering — it isn't.
            //
            // That constraint is also why the notes row below repeats this
            // markup instead of sharing it: factoring it out would have to
            // pull this one with it.
            ForEach(inlineOrder) { kind in
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
                        // The glyph the pill itself uses, so this list reads as
                        // a preview of the row rather than as an index of it.
                        Image(systemName: kind.systemImage)
                            .foregroundStyle(
                                preferences.enabledPills.contains(kind)
                                    ? Color.accentColor : .secondary
                            )
                    }
                }
            }
            .reorderable()

            // Notes sits outside the reorderable list because a cue note is
            // long-form text: it gets a line of its own beneath the pills, and
            // no position in the order can change that. It was previously
            // draggable, which offered the operator a control that did nothing.
            // It stays switchable, because whether notes appear at all is a
            // real choice.
            Section {
                Toggle(isOn: Binding {
                    preferences.enabledPills.contains(.notes)
                } set: { isEnabled in
                    if isEnabled {
                        preferences.enabledPills.insert(.notes)
                    } else {
                        preferences.enabledPills.remove(.notes)
                    }
                    Task { await client.refreshPlayheadCueDetails() }
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
            } footer: {
                Text("Notes always appear on their own line beneath the pills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .reorderContainer(for: DetailPillKind.self) { difference in
            apply(difference, to: preferences)
        }
        // A bottom bar as a safe-area inset rather than a `Divider` inside a
        // `VStack`: the list then scrolls under it and the bar picks up the
        // standard material, the same as the Activity Log's status bar.
        .safeAreaInset(edge: .bottom) {
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
            .background(.bar)
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
