import SwiftUI

struct CueDrawerView: View {
    var maxHeight: CGFloat?

    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        if client.status.hasLiveData,
           let graph = client.watchedGraph,
           let cueID = client.currentPlayheadCueID {
            content(graph: graph, playheadID: cueID)
        }
    }

    @ViewBuilder
    private func content(graph: CueGraph, playheadID: String) -> some View {
        let neighbourhood = graph.neighbourhood(
            around: playheadID,
            above: model.preferences.drawerRowsAboveCount,
            below: model.preferences.drawerRowsBelowCount
        )

        VStack(alignment: .leading, spacing: 0) {
            Divider()

            rows(
                graph: graph,
                playheadID: playheadID,
                above: neighbourhood.above,
                below: neighbourhood.below
            )
        }
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cue list around the playhead")
    }

    @ViewBuilder
    private func rows(
        graph: CueGraph, playheadID: String, above: [Cue], below: [Cue]
    ) -> some View {
        let stack = VStack(alignment: .leading, spacing: 2) {
            if graph.isFirst(playheadID) {
                boundaryRow("Top of cue list", systemImage: "arrow.up.to.line")
            } else {
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

    private func playheadMarker(insideGroup group: Cue?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(.tint)

            if let group {
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
    @ViewBuilder
    func scrollingBound(to maxHeight: CGFloat?) -> some View {
        if let maxHeight {
            BoundedHeightLayout(maxHeight: maxHeight) {
                ViewThatFits(in: .vertical) {
                    self

                    ScrollView(.vertical) { self }
                        .defaultScrollAnchor(.center)
                }
            }
        } else {
            self
        }
    }
}

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

    private func limiting(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: proposal.width,
            height: min(proposal.height ?? .infinity, maxHeight)
        )
    }
}

struct CueRowView: View {
    enum Role: Hashable {
        case above(distance: Int)
        case below(distance: Int)

        static let largestRowFontSize: CGFloat = 22

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

        static let nameSizeRatio: CGFloat = 0.82

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
                max(0.35, 0.62 - Double(distance - 1) * 0.12)
            case .below(let distance):
                distance == 1 ? 1.0 : max(0.5, 0.85 - Double(distance - 2) * 0.15)
            }
        }

        var isFocalRow: Bool {
            if case .below(1) = self { return true }
            return false
        }

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
        .contentTransition(.identity)
        .padding(.vertical, role.isFocalRow ? 3 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var nameStyle: AnyShapeStyle {
        guard cue.displayName != nil else { return AnyShapeStyle(.tertiary) }
        guard let color = cue.color else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color)
    }

    private var numberColumn: some View {
        Text(verbatim: "000.0")
            .font(typography.drawerNumber(size: Role.largestRowFontSize, weight: .semibold))
            .monospacedDigit()
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .trailingFirstTextBaseline) {
                Text(cue.displayNumber ?? "–")
                    .font(typography.drawerNumber(size: role.fontSize, weight: role.weight))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
    }

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

#Preview("Drawer at maximum rows") {
    func cue(_ number: Int) -> Cue {
        var cue = Cue(uniqueID: "\(number)")
        cue.number = "\(number)"
        cue.name = "Cue number \(number)"
        return cue
    }

    let height: CGFloat = 560

    return VStack(spacing: 0) {
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
            .scrollingBound(to: height * MainWindowView.drawerHeightShare)
        }
        .background(.thinMaterial)
    }
    .frame(width: 900, height: height)
    .environment(AppModel())
}

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
