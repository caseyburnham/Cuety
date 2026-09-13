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
    /// The most vertical space the drawer may take, or `nil` for unbounded.
    ///
    /// Supplied by the window rather than chosen here, because "how much of
    /// the display may the drawer eat" is a question about the window, and the
    /// answer has to hold at every window size.
    var maxHeight: CGFloat?

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

            rows(graph: graph, playheadID: playheadID, above: above, below: below)
        }
        // A thinner material than the app's status bars use, because this is a
        // content area rather than a strip of chrome: the cue rows should read
        // as sitting on the window, not on a toolbar.
        .background(.thinMaterial)
        .motion(Motion.drawerShift, value: playheadID)
        .accessibilityElement(children: .contain)
        // Named for what it is — a window onto the list — rather than for the
        // furniture it is drawn as. VoiceOver users get the same guarantee the
        // row labels give: position, not playback.
        .accessibilityLabel("Cue list around the playhead")
    }

    /// The rows, bounded so the drawer can never take the display's space.
    ///
    /// Ten rows above and ten below — both allowed by Settings — come to more
    /// than the height of the window Cuety opens at. Unbounded, the drawer
    /// reduced the headline cue number to a clipped sliver *and* lost its own
    /// furthest rows off the bottom edge with nothing to say so.
    ///
    /// So it scrolls, anchored on the centre. Scrolling is not much use on a
    /// display nobody is standing at, but the rows either side of the playhead
    /// are the ones that matter and the anchor keeps those on screen; the rows
    /// that fall outside are the distant ones, and they remain reachable rather
    /// than silently cut off.
    @ViewBuilder
    private func rows(
        graph: CueGraph, playheadID: String, above: [Cue], below: [Cue]
    ) -> some View {
        let stack = VStack(alignment: .leading, spacing: 2) {
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

        stack.scrollingBound(to: maxHeight)
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

extension View {
    /// Confines a view to `maxHeight`, scrolling what does not fit instead of
    /// clipping it.
    ///
    /// - Parameter maxHeight: The bound, or `nil` to impose none.
    ///
    /// A `nil` bound returns the view untouched rather than wrapping it in a
    /// scroll view that happens to be large enough. That distinction matters:
    /// a `ScrollView` expands to fill whatever it is offered whether its
    /// content needs the room or not, which is precisely the fault this is here
    /// to prevent.
    ///
    /// When bounded, the height is `min(content, maxHeight)`:
    /// ``BoundedHeightLayout`` narrows the offer to the bound, and
    /// `ViewThatFits` spends it on the plain content when that fits and on a
    /// scroll view only when it does not.
    ///
    /// `.frame(maxHeight:)` is conspicuously absent, and that is the point. A
    /// flexible frame *grows to fill what it is offered*, up to its maximum —
    /// it does not shrink-wrap — so capping the drawer that way made it 252pt
    /// tall to show three rows, taking the cue number's space to no purpose.
    /// ``DrawerBoundTests`` measured 252 where 72 was wanted, including for
    /// plain content with no scroll view anywhere near it.
    ///
    /// `fixedSize` does make such a frame shrink-wrap, but only by proposing
    /// `nil` inwards, and `ViewThatFits` needs the real bound to choose
    /// against. Hence a layout: it can limit the proposal without having an
    /// appetite of its own.
    @ViewBuilder
    func scrollingBound(to maxHeight: CGFloat?) -> some View {
        if let maxHeight {
            BoundedHeightLayout(maxHeight: maxHeight) {
                ViewThatFits(in: .vertical) {
                    self

                    ScrollView(.vertical) { self }
                        // The rows either side of the playhead are the ones
                        // that matter, so they are what stays on screen when
                        // the content outgrows the bound.
                        .defaultScrollAnchor(.center)
                }
            }
        } else {
            self
        }
    }
}

/// Offers its content at most `maxHeight`, and is exactly as tall as the
/// content turns out to be.
///
/// Neither half of that is what `.frame(maxHeight:)` does, which is why this
/// exists — see ``SwiftUICore/View/scrollingBound(to:)``.
struct BoundedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(limiting(proposal))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: limiting(proposal)
        )
    }

    /// An unspecified height means "however much you like", which is more than
    /// the bound by definition — so the bound is the answer either way.
    private func limiting(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: proposal.width,
            height: min(proposal.height ?? .infinity, maxHeight)
        )
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
        // Typography snaps; position and opacity still animate.
        //
        // When the playhead advances, the two rows below it keep their
        // identity and change ``Role`` — which changes their font size and
        // weight. SwiftUI's default content transition tries to interpolate
        // that, and falls back to cross-fading the old and new text when it
        // can't: two half-opaque copies of the same number, which reads as the
        // row briefly turning grey. It was only ever the next two rows,
        // because they are the only ones whose size changes at all.
        .contentTransition(.identity)
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
                    .rotationEffect(DetailPillKind.armed.glyphRotation)
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

/// `F14` reproduction: the drawer at its maximum configured size, in a window
/// the size Cuety opens at.
///
/// Settings allows ten rows above the playhead and ten below, which together
/// come to more than 560pt. Unbounded, the drawer reduced the headline cue
/// number to a clipped sliver of glyph tops *and* still lost rows 17–20 off
/// the bottom edge with nothing to indicate it.
///
/// The bound is the one the window passes — 45% of the detail height — so this
/// renders the real arithmetic, not a stand-in for it.
#Preview("Drawer at maximum rows") {
    func cue(_ number: Int) -> Cue {
        var cue = Cue(uniqueID: "\(number)")
        cue.number = "\(number)"
        cue.name = "Cue number \(number)"
        return cue
    }

    let height: CGFloat = 560

    return VStack(spacing: 0) {
        // Stands in for the cue display the drawer is inset into.
        Text("42")
            .font(.system(size: 160, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(1...10, id: \.self) {
                    CueRowView(cue: cue($0), role: .above(distance: 11 - $0))
                }
                Rectangle().fill(.tint.opacity(0.5))
                    .frame(height: 1).padding(.vertical, 5)
                ForEach(1...10, id: \.self) {
                    CueRowView(cue: cue($0 + 10), role: .below(distance: $0))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // The real mechanism, given the bound the window would pass.
            .scrollingBound(to: height * MainWindowView.drawerHeightShare)
        }
        .background(.thinMaterial)
    }
    // The app's own `defaultSize`.
    .frame(width: 900, height: height)
    .environment(AppModel())
}

/// `F14` reproduction: cue numbers the hidden `"000.0"` template cannot fit.
///
/// QLab numbers are free text. Anything wider than five monospaced digits —
/// a three-part number, a lettered number, a longer decimal — has to go
/// somewhere, and the template decides how much room there is.
#Preview("Awkward cue numbers") {
    let numbers = ["1", "12.5", "100.25", "A12", "1.1.1", "SQ-104"]

    return VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(numbers.enumerated()), id: \.offset) { offset, number in
            var cue = Cue(uniqueID: number)
            cue.number = number
            cue.name = "Cue named \(number)"
            return CueRowView(cue: cue, role: .below(distance: offset + 1))
        }
    }
    .padding(20)
    .frame(width: 420)
    .environment(AppModel())
}
