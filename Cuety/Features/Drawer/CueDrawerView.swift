import SwiftUI

/// The bottom drawer: the cue list either side of the playhead.
///
/// A window onto the watched cue list, centred on the row the playhead is
/// parked on. Everything here is *list position* and nothing more. It does not
/// know which cues have fired — moving the playhead by hand changes every row
/// without anything having been taken — and the row below the playhead is not
/// a prediction of what the next GO will do, because a group's mode decides
/// that and this drawer has no model of group execution.
///
/// A group is one row, and the cues inside it are not rows. That is the list
/// as QLab draws it, and as the operator holds it in their head: a group is a
/// single line until they open it. Expanding groups here turned a four-cue
/// show with one group into a dozen rows of things nobody was looking for.
/// When the playhead is parked on a cue *inside* a group, the group is still
/// the row and the marker names it — see ``playheadMarker(insideGroup:)``.
///
/// The typographic hierarchy is the whole point. Rows above the playhead
/// recede — smaller, dimmer. The row directly below it is the most prominent
/// thing after the playhead itself, and each row beyond steps down again. An
/// operator should be able to read their position in the list from the shape
/// of it without reading a single number.
struct CueDrawerView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        // The live-session check is the drawer's own, not something inherited
        // from the client having cleared its cue data — see
        // ``CueDisplayView/liveCue``. Rows around a playhead QLab has stopped
        // confirming are the same lie the display refuses to tell.
        if client.status.hasLiveData,
           let graph = client.watchedGraph,
           let cueID = client.currentPlayheadCueID {
            content(graph: graph, playheadID: cueID)
        }
    }

    @ViewBuilder
    private func content(graph: CueGraph, playheadID: String) -> some View {
        let above = graph.rowsAbove(
            playheadID, count: model.preferences.drawerRowsAboveCount
        )
        let below = graph.rowsBelow(
            playheadID, count: model.preferences.drawerRowsBelowCount
        )

        VStack(alignment: .leading, spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                // The boundary rows are driven by the graph, not by an empty
                // slice: with the drawer set to show no rows above, "Top of
                // cue list" would otherwise be claimed on every cue in the show.
                if graph.isFirst(playheadID) {
                    boundaryRow("Top of cue list", systemImage: "arrow.up.to.line")
                } else {
                    // Nearest-last, so the row adjacent to the playhead is the
                    // one directly above it in the list.
                    ForEach(Array(above.enumerated()), id: \.element.id) { offset, cue in
                        CueRowView(
                            cue: cue,
                            role: .above(distance: above.count - offset)
                        )
                    }
                }

                playheadMarker(insideGroup: graph.containingRow(of: playheadID))

                if graph.isLast(playheadID) {
                    boundaryRow("End of cue list", systemImage: "arrow.down.to.line")
                } else {
                    ForEach(Array(below.enumerated()), id: \.element.id) { offset, cue in
                        CueRowView(cue: cue, role: .below(distance: offset + 1))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // A thinner material than the app's status bars use, because this is a
        // content area rather than a strip of chrome: the cue rows should read
        // as sitting on the window, not on a toolbar.
        .background(.thinMaterial)
        .animation(Motion.drawerShift, value: playheadID)
        .accessibilityElement(children: .contain)
        // Named for what it is — a window onto the list — rather than for the
        // furniture it is drawn as. VoiceOver users get the same guarantee the
        // row labels give: position, not playback.
        .accessibilityLabel("Cue list around the playhead")
    }

    /// A thin rule marking the playhead's row in the list.
    ///
    /// - Parameter group: The group the playhead is inside, when it is parked
    ///   on one of that group's cues rather than on a row of its own. The
    ///   marker names it, because the group is drawn as a single row and the
    ///   cue at the playhead is not drawn at all — so an unlabelled rule would
    ///   appear to sit between two unrelated rows.
    private func playheadMarker(insideGroup group: Cue?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(.tint)

            if let group {
                // "Untitled" is the drawer's word for a nameless cue already,
                // so a nameless group uses it here too rather than inventing
                // a second placeholder.
                Text("in \(group.displayName ?? "Untitled")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Rectangle()
                .fill(.tint.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.vertical, 5)
        // Hidden when it is only a rule: every row already announces its own
        // distance from the playhead, so saying so again adds nothing. Not
        // hidden when the playhead is inside a group, because that is the one
        // fact no row can convey.
        .accessibilityHidden(group == nil)
        .accessibilityLabel(
            group.map { "Playhead, inside \($0.displayName ?? "Untitled")" } ?? "Playhead"
        )
    }

    private func boundaryRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 3)
    }
}

/// One row in the drawer.
struct CueRowView: View {
    /// Where this cue sits in the list relative to the playhead's row, which
    /// drives every typographic decision in the row.
    ///
    /// Positions, not playback states. `distance` counts rows in the flattened
    /// cue list; it says nothing about what has fired or what will fire next.
    enum Role: Hashable {
        /// Above the playhead's row. `distance` is 1 for the row directly above.
        case above(distance: Int)
        /// Below the playhead's row. `distance` is 1 for the row directly below.
        case below(distance: Int)

        /// The size of the drawer's most prominent row — the one directly below
        /// the playhead. Every other size steps down from here, and the number
        /// column is laid out from it so every row's number lands on the same
        /// edge.
        static let largestRowFontSize: CGFloat = 22

        /// Rows below the playhead get progressively smaller; rows above are
        /// uniformly small, because where the list is going matters more to an
        /// operator reading it than how far back it has come.
        var fontSize: CGFloat {
            switch self {
            case .above: 13
            case .below(let distance):
                switch distance {
                case 1: Self.largestRowFontSize
                case 2: 17
                default: 14
                }
            }
        }

        /// The name is set a little smaller than the number it sits beside, so
        /// the number stays the thing the eye lands on first.
        static let nameSizeRatio: CGFloat = 0.82

        /// Indicators are small enough to read as annotations on the row rather
        /// than as content, with a floor so they don't vanish on the small rows
        /// above the playhead.
        static let indicatorSizeRatio: CGFloat = 0.55
        static let minimumIndicatorSize: CGFloat = 9

        var weight: Font.Weight {
            switch self {
            case .above: .regular
            case .below(let distance): distance == 1 ? .semibold : .regular
            }
        }

        var opacity: Double {
            switch self {
            case .above(let distance):
                // Fades with distance, but never to the point of illegibility.
                max(0.35, 0.62 - Double(distance - 1) * 0.12)
            case .below(let distance):
                distance == 1 ? 1.0 : max(0.5, 0.85 - Double(distance - 2) * 0.15)
            }
        }

        /// The row directly below the playhead — the drawer's focal row.
        var isFocalRow: Bool {
            if case .below(1) = self { return true }
            return false
        }

        /// Position in the list, stated as position.
        ///
        /// This used to say "Just taken" and "Next", which a static traversal
        /// of the cue list has no basis for: skipping the playhead by hand
        /// fires nothing, and a group's mode decides what the next GO takes.
        var accessibilityPrefix: String {
            switch self {
            case .above(1): "1 row above the playhead"
            case .above(let distance): "\(distance) rows above the playhead"
            case .below(1): "1 row below the playhead"
            case .below(let distance): "\(distance) rows below the playhead"
            }
        }
    }

    let cue: Cue
    let role: Role

    @Environment(AppModel.self) private var model

    private var typography: Typography { Typography(preferences: model.preferences) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            numberColumn
                .foregroundStyle(cue.displayNumber == nil ? .tertiary : .primary)

            Text(cue.displayName ?? "Untitled")
                // The operator's chosen family, the same as the number beside
                // it: a drawer that mixed families across one row would look
                // like two different apps.
                .font(typography.cueName(
                    size: role.fontSize * Role.nameSizeRatio, weight: role.weight
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(nameStyle)

            Spacer(minLength: 0)

            trailingIndicators
        }
        .opacity(role.opacity)
        .padding(.vertical, role.isFocalRow ? 3 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The cue's own colour from QLab, the same as the display gives the
    /// headline name — a cue flagged green in the drawer is the one that will
    /// be green when it reaches the playhead.
    ///
    /// A placeholder name stays hierarchical: "Untitled" is Cuety's word, not
    /// the operator's, so it should never be shown in a colour they chose.
    private var nameStyle: AnyShapeStyle {
        guard cue.displayName != nil else { return AnyShapeStyle(.tertiary) }
        guard let color = cue.color else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color)
    }

    /// Numbers share a right-aligned column so they line up as a scale the eye
    /// can read down, rather than ragged text.
    ///
    /// The column's width comes from laying out a hidden template at the
    /// drawer's largest row size and drawing the real number over it. A fixed
    /// point value would be a guess that silently stops fitting the moment the
    /// operator picks a wider font family.
    private var numberColumn: some View {
        Text(verbatim: "000.0")
            .font(typography.drawerNumber(size: Role.largestRowFontSize, weight: .semibold))
            .monospacedDigit()
            .hidden()
            .accessibilityHidden(true)
            // Baseline-aligned, not centred: the template is always the
            // largest row's size, so a smaller row's number has to sit on the
            // template's baseline or it drifts away from the name beside it.
            .overlay(alignment: .trailingFirstTextBaseline) {
                Text(cue.displayNumber ?? "–")
                    .font(typography.drawerNumber(size: role.fontSize, weight: role.weight))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
    }

    /// Only the states worth interrupting for: a disarmed cue that will not
    /// fire, a flag the operator set deliberately, and a cue that takes the
    /// next one with it.
    private var trailingIndicators: some View {
        HStack(spacing: 5) {
            if cue.isArmed == false {
                Image(systemName: DetailPillKind.armed.systemImage)
                    .foregroundStyle(.red)
                    .help("Disarmed — this cue will not fire")
            }
            if cue.isFlagged == true {
                Image(systemName: DetailPillKind.flagged.systemImage)
                    .foregroundStyle(.yellow)
                    .help("Flagged")
            }
            if let mode = cue.continueMode, mode != .doNotContinue {
                Image(systemName: mode.systemImage)
                    .foregroundStyle(.blue)
                    .help(mode.title)
            }
        }
        .font(.system(size: max(
            Role.minimumIndicatorSize, role.fontSize * Role.indicatorSizeRatio
        )))
    }

    private var accessibilityDescription: String {
        var parts = [role.accessibilityPrefix]
        if let number = cue.displayNumber { parts.append("cue \(number)") }
        if let name = cue.displayName { parts.append(name) }
        if cue.isArmed == false { parts.append("disarmed") }
        if cue.isFlagged == true { parts.append("flagged") }
        if let mode = cue.continueMode, mode != .doNotContinue {
            parts.append(mode.title)
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    CueDrawerView()
        .environment(AppModel())
        .frame(width: 900)
}
