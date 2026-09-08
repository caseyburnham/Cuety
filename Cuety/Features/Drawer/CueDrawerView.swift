import SwiftUI

/// The bottom drawer: cues already taken above, cues coming up below.
///
/// The typographic hierarchy is the whole point. Taken cues recede — smaller,
/// dimmer. The next cue is the most prominent thing after the playhead itself,
/// and each cue beyond it steps down again. An operator should be able to read
/// their position in the show from the shape of this list without reading a
/// single number.
struct CueDrawerView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        if let graph = client.watchedGraph, let cueID = client.currentPlayheadCueID {
            content(graph: graph, playheadID: cueID)
        }
    }

    @ViewBuilder
    private func content(graph: CueGraph, playheadID: String) -> some View {
        let previous = graph.previous(
            before: playheadID, count: model.preferences.drawerPreviousCount
        )
        let upcoming = graph.upcoming(
            after: playheadID, count: model.preferences.drawerUpcomingCount
        )

        VStack(alignment: .leading, spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                // The boundary rows are driven by the graph, not by an empty
                // slice: with the drawer set to show no previous cues, "Top of
                // cue list" would otherwise be claimed on every cue in the show.
                if graph.isFirst(playheadID) {
                    boundaryRow("Top of cue list", systemImage: "arrow.up.to.line")
                } else {
                    // Nearest-last, so the row adjacent to the playhead is the
                    // one that just fired.
                    ForEach(Array(previous.enumerated()), id: \.element.id) { offset, cue in
                        CueRowView(
                            cue: cue,
                            role: .taken(distance: previous.count - offset)
                        )
                    }
                }

                playheadMarker

                if graph.isLast(playheadID) {
                    boundaryRow("End of cue list", systemImage: "arrow.down.to.line")
                } else {
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { offset, cue in
                        CueRowView(cue: cue, role: .upcoming(distance: offset + 1))
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
        .accessibilityLabel("Cue drawer")
    }

    /// A thin rule marking where the playhead sits between taken and upcoming.
    private var playheadMarker: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(.tint)

            Rectangle()
                .fill(.tint.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.vertical, 5)
        .accessibilityHidden(true)
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
    /// Where this cue sits relative to the playhead, which drives every
    /// typographic decision in the row.
    enum Role: Hashable {
        /// Already fired. `distance` is 1 for the most recent.
        case taken(distance: Int)
        /// Coming up. `distance` is 1 for the next cue.
        case upcoming(distance: Int)

        /// The size of the drawer's most prominent row — the next cue's. Every
        /// other size steps down from here, and the number column is laid out
        /// from it so every row's number lands on the same edge.
        static let nextCueFontSize: CGFloat = 22

        /// Upcoming cues get progressively smaller; taken cues are uniformly
        /// small, because how long ago something fired matters less than how
        /// soon something is coming.
        var fontSize: CGFloat {
            switch self {
            case .taken: 13
            case .upcoming(let distance):
                switch distance {
                case 1: Self.nextCueFontSize
                case 2: 17
                default: 14
                }
            }
        }

        /// The name is set a little smaller than the number it sits beside, so
        /// the number stays the thing the eye lands on first.
        static let nameSizeRatio: CGFloat = 0.82

        /// Indicators are small enough to read as annotations on the row rather
        /// than as content, with a floor so they don't vanish on taken cues.
        static let indicatorSizeRatio: CGFloat = 0.55
        static let minimumIndicatorSize: CGFloat = 9

        var weight: Font.Weight {
            switch self {
            case .taken: .regular
            case .upcoming(let distance): distance == 1 ? .semibold : .regular
            }
        }

        var opacity: Double {
            switch self {
            case .taken(let distance):
                // Fades with age, but never to the point of illegibility.
                max(0.35, 0.62 - Double(distance - 1) * 0.12)
            case .upcoming(let distance):
                distance == 1 ? 1.0 : max(0.5, 0.85 - Double(distance - 2) * 0.15)
            }
        }

        var isNext: Bool {
            if case .upcoming(1) = self { return true }
            return false
        }

        var accessibilityPrefix: String {
            switch self {
            case .taken(1): "Just taken"
            case .taken(let distance): "\(distance) cues ago"
            case .upcoming(1): "Next"
            case .upcoming(let distance): "\(distance) cues ahead"
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
        .padding(.vertical, role.isNext ? 3 : 1)
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
            .font(typography.drawerNumber(size: Role.nextCueFontSize, weight: .semibold))
            .monospacedDigit()
            .hidden()
            .accessibilityHidden(true)
            // Baseline-aligned, not centred: the template is always the next
            // cue's size, so a smaller row's number has to sit on the
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
