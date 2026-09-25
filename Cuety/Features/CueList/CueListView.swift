import SwiftUI

/// The cue list layout: the standby cue as large as the display draws it,
/// marked by a fixed playhead arrow, with the cues either side of it centred
/// above and below. The list turns like a drum on a go: the next cue slides
/// up and grows into the standby position while the cue just taken slides
/// up and shrinks into the previous one.
struct CueListView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        if !model.isDataStale,
           client.status.hasLiveData,
           let graph = client.watchedGraph,
           let standby = client.liveCue,
           let index = graph.rowIndex(of: standby.uniqueID) {
            CueDrum(graph: graph, standby: standby, standbyIndex: index)
        } else {
            // Connection, empty and stale states read the same in either layout.
            CueDisplayView()
        }
    }
}

/// Everything that stays put while the drum turns — the arrow, the detail
/// pills, the canvas tint — around the rows that move.
private struct CueDrum: View {
    let graph: CueGraph
    let standby: Cue
    let standbyIndex: Int

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headlineSizingCache = HeadlineSizingCache()

    /// The row index the drum is turned to. It trails `standbyIndex` so the
    /// change can be animated, and is nil until the drum first appears.
    @State private var displayedOffset: Double?

    /// The pills' own height, for when they wrap past the room reserved.
    @State private var measuredPillsHeight: CGFloat = 0

    /// A jump further than this, such as the operator setting the playhead
    /// by hand, snaps rather than spinning the drum through every cue.
    static let maximumAnimatedJump = 3

    static let arrowSizeRatio: CGFloat = 0.3
    static let arrowSpacingRatio: CGFloat = 0.06
    static let horizontalPadding: CGFloat = 32

    private var typography: Typography { Typography(preferences: model.preferences) }

    private var pillSize: PillSize {
        horizontalSizeClass == .compact ? .small : model.preferences.pillSize
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = metrics(in: proxy.size)

            ZStack {
                DrumRows(
                    offset: displayedOffset ?? Double(standbyIndex),
                    rows: graph.rows,
                    standby: standby,
                    standbyIndex: standbyIndex,
                    metrics: metrics
                )

                PlayheadArrow(
                    size: metrics.arrowSize,
                    color: model.preferences.playheadAccent.color(for: standby)
                )
                    .position(x: metrics.arrowX, y: metrics.numberCenterY)

                if !model.isPresenting {
                    VStack {
                        Spacer(minLength: 0)
                        DetailPillsRow(
                            cue: standby,
                            kinds: model.preferences.visiblePills,
                            cueListName: watchedCueListName,
                            size: pillSize,
                            showsCueTypeLabel: model.preferences.showsCueTypeLabel,
                            performanceMode: model.preferences.performanceMode
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            measuredPillsHeight = height
                        }
                        // Without a note the pills fill only part of the room
                        // kept for them, so they sit in its middle rather than
                        // leaving the whole spare row between them and the name.
                        .frame(height: pillsHeight)
                        .animation(animatesShift ? Motion.pill : nil, value: standbyHasNote)
                    }
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.bottom, metrics.pillsBottomInset)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .clipped()
        .background {
            (standby.color ?? .clear)
                .opacity(CueDisplayView.canvasTintOpacity)
                .animation(animatesShift ? Motion.listShift : nil, value: standby.uniqueID)
        }
        .onChange(of: standbyIndex, initial: true) { old, new in
            let target = Double(new)
            guard displayedOffset != nil,
                  animatesShift,
                  new != old,
                  abs(new - old) <= Self.maximumAnimatedJump
            else {
                displayedOffset = target
                return
            }
            withAnimation(Motion.listShift) { displayedOffset = target }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cue list around the playhead")
    }

    /// Room for the pills whether or not the standby cue has a note, so the
    /// number, name and arrow hold still from one cue to the next. Notes sit
    /// on a row of their own beneath the other pills.
    private var pillsHeight: CGFloat {
        let rows: CGFloat = model.preferences.visiblePills.contains(.notes) ? 2 : 1
        let reserved = pillSize.height * rows + pillSize.spacing * (rows - 1)
        return max(reserved, measuredPillsHeight)
    }

    private var standbyHasNote: Bool {
        !(standby.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var animatesShift: Bool {
        !model.preferences.performanceMode && !reduceMotion
    }

    private var watchedCueListName: String? {
        model.client.cueLists.first { $0.uniqueID == model.client.watchedCueListID }?.displayName
    }

    /// Lays the standby position out the way the display does: the number
    /// fills what the name and pills leave, and the arrow sits beside the
    /// widest number in the list so it never has to move between cues.
    private func metrics(in size: CGSize) -> DrumMetrics {
        let presenting = model.isPresenting
        let showsName = model.preferences.showsCueName
        let nameSize: CGFloat = presenting ? 40 : 28
        let padding = DrumMetrics.contentPadding

        let nameBlock = showsName ? nameSize * 1.25 + DrumLabelLayout.stackedSpacing : 0
        let pillBlock = presenting ? 0 : pillsHeight + 12
        let areaHeight = size.height - DrumMetrics.bandHeight * 2
        let numberHeight = max(0, areaHeight - padding * 2 - nameBlock - pillBlock)
        let numberWidth = max(0, size.width - Self.horizontalPadding * 2)

        let reference = headlineSizingCache.referenceNumber(
            for: standby.displayNumber ?? "–",
            cueNumbers: graph.cueNumbers,
            typography: typography
        )
        // Fit once for the arrow's size, then again in the width the arrow
        // and a matching margin on the other side leave over.
        let firstFit = typography.cueNumberPointSize(
            fitting: reference, in: CGSize(width: numberWidth, height: numberHeight)
        )
        let reserved = 2 * firstFit * (Self.arrowSizeRatio + Self.arrowSpacingRatio)
        let numberSize = typography.cueNumberPointSize(
            fitting: reference,
            in: CGSize(width: max(0, numberWidth - reserved), height: numberHeight)
        )

        let arrowSize = numberSize * Self.arrowSizeRatio
        let referenceWidth = typography.cueNumberWidth(of: reference, size: numberSize)
        let arrowX = max(
            Self.horizontalPadding / 2 + arrowSize / 2,
            size.width / 2 - referenceWidth / 2 - numberSize * Self.arrowSpacingRatio - arrowSize / 2
        )

        return DrumMetrics(
            size: size,
            standbyNumberSize: numberSize,
            standbyNameSize: nameSize,
            showsStandbyName: showsName,
            numberCenterY: DrumMetrics.bandHeight + padding + numberHeight / 2,
            arrowSize: arrowSize,
            arrowX: arrowX,
            pillsBottomInset: DrumMetrics.bandHeight + padding
        )
    }
}

/// Where and how large each position on the drum draws its cue. Position
/// zero is standby; negative positions are earlier cues, positive later.
private struct DrumMetrics {
    static let rowPitch: CGFloat = 34
    static let bandPadding: CGFloat = 12
    static let contentPadding: CGFloat = 16
    /// Positions past this are off the drum: faded out beyond each band.
    static let lastPosition = CueLayout.listRowRadius + 1

    /// Both bands share one height so the standby cue sits in the middle.
    static var bandHeight: CGFloat {
        CGFloat(CueLayout.listRowRadius) * rowPitch + bandPadding * 2
    }

    let size: CGSize
    let standbyNumberSize: CGFloat
    let standbyNameSize: CGFloat
    let showsStandbyName: Bool
    let numberCenterY: CGFloat
    let arrowSize: CGFloat
    let arrowX: CGFloat
    let pillsBottomInset: CGFloat

    private static func role(at position: Int) -> CueRowView.Role {
        position < 0 ? .above(distance: -position) : .below(distance: position)
    }

    func y(at position: Double) -> CGFloat {
        interpolate(position) { position in
            let distance = CGFloat(abs(position)) - 0.5
            if position == 0 {
                return numberCenterY
            } else if position < 0 {
                return Self.bandHeight - Self.bandPadding - distance * Self.rowPitch
            } else {
                return size.height - Self.bandHeight + Self.bandPadding + distance * Self.rowPitch
            }
        }
    }

    func numberSize(at position: Double) -> CGFloat {
        interpolate(position, logarithmic: true) { position in
            position == 0 ? standbyNumberSize : Self.role(at: position).fontSize
        }
    }

    func nameSize(at position: Double) -> CGFloat {
        interpolate(position, logarithmic: true) { position in
            position == 0
                ? standbyNameSize
                : Self.role(at: position).fontSize * CueRowView.Role.nameSizeRatio
        }
    }

    func opacity(at position: Double) -> CGFloat {
        interpolate(position) { position in
            if position == 0 { return 1 }
            if abs(position) >= Self.lastPosition { return 0 }
            return Self.role(at: position).opacity
        }
    }

    func nameOpacity(at position: Double) -> CGFloat {
        interpolate(position) { position in
            position == 0 && !showsStandbyName ? 0 : 1
        }
    }

    /// How far a cue has turned from a row into the standby arrangement.
    func stacking(at position: Double) -> CGFloat {
        CGFloat(max(0, 1 - abs(position)))
    }

    /// Blends the values either side of a fractional position. Sizes blend
    /// logarithmically so the standby number grows at an even pace.
    private func interpolate(
        _ position: Double, logarithmic: Bool = false, _ value: (Int) -> CGFloat
    ) -> CGFloat {
        let last = Double(Self.lastPosition)
        let clamped = min(last, max(-last, position))
        let lower = Int(clamped.rounded(.down))
        let upper = min(Self.lastPosition, lower + 1)
        let fraction = CGFloat(clamped - Double(lower))
        let from = value(lower), to = value(upper)

        if logarithmic, from > 0, to > 0 {
            return exp(log(from) + (log(to) - log(from)) * fraction)
        }
        return from + (to - from) * fraction
    }
}

/// The turning part of the drum. Its offset is animatable, so every frame
/// of a go lays each cue out afresh at its in-between position and size.
private struct DrumRows: View, Animatable {
    var offset: Double
    let rows: [Cue]
    let standby: Cue
    let standbyIndex: Int
    let metrics: DrumMetrics

    var animatableData: Double {
        get { offset }
        set { offset = newValue }
    }

    var body: some View {
        let reach = Double(DrumMetrics.lastPosition)
        let first = max(-1, Int((offset - reach).rounded(.down)))
        let last = min(rows.count, Int((offset + reach).rounded(.up)))

        ZStack {
            ForEach(Array(first...last), id: \.self) { index in
                let position = Double(index) - offset
                item(at: index, position: position)
                    .position(x: metrics.size.width / 2, y: metrics.y(at: position))
                    .opacity(metrics.opacity(at: position))
                    .accessibilityHidden(abs(position) > Double(CueLayout.listRowRadius) + 0.5)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
    }

    @ViewBuilder
    private func item(at index: Int, position: Double) -> some View {
        if index < 0 || index >= rows.count {
            Label(
                index < 0 ? "Top of cue list" : "End of cue list",
                systemImage: index < 0 ? "arrow.up.to.line" : "arrow.down.to.line"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
            // Between standby and a row, the row end is the one on this side;
            // further out the cue is only ever a row, so it is its own row end.
            let rowEnd = abs(position) < 1 ? (position < 0 ? -1.0 : 1.0) : position

            // A standby cue inside a group stands in for the group's row.
            DrumLabel(
                cue: index == standbyIndex ? standby : rows[index],
                numberSize: metrics.numberSize(at: position),
                nameSize: metrics.nameSize(at: position),
                nameOpacity: metrics.nameOpacity(at: position),
                stacking: metrics.stacking(at: position),
                maxWidth: metrics.size.width - CueDrum.horizontalPadding * 2,
                rowNumberSize: metrics.numberSize(at: rowEnd),
                rowNameSize: metrics.nameSize(at: rowEnd),
                standbyNumberSize: metrics.numberSize(at: 0),
                standbyNameSize: metrics.nameSize(at: 0)
            )
        }
    }
}

/// One cue's number and name, laid out inline as a row or stacked as the
/// standby cue, or anywhere in between.
private struct DrumLabel: View {
    let cue: Cue
    let numberSize: CGFloat
    let nameSize: CGFloat
    let nameOpacity: CGFloat
    let stacking: CGFloat
    let maxWidth: CGFloat
    /// The sizes at the row and standby ends of the current move.
    let rowNumberSize: CGFloat
    let rowNameSize: CGFloat
    let standbyNumberSize: CGFloat
    let standbyNameSize: CGFloat

    @Environment(AppModel.self) private var model

    private var typography: Typography { Typography(preferences: model.preferences) }

    var body: some View {
        DrumLabelLayout(
            stacking: stacking,
            maxWidth: maxWidth,
            rowNumberScale: rowNumberSize / numberSize,
            rowNameScale: rowNameSize / nameSize,
            standbyNumberScale: standbyNumberSize / numberSize,
            standbyNameScale: standbyNameSize / nameSize
        ) {
            Text(cue.displayNumber ?? "–")
                .font(typography.cueNumber(size: numberSize))
                .monospacedDigit()
                .foregroundStyle(cue.displayNumber == nil ? .tertiary : .primary)
                .lineLimit(1)
                .fixedSize()

            // Rows tint the name with the cue color; the standby cue leaves
            // that to the canvas. The two cross-fade as the cue turns.
            ZStack {
                Text(cue.displayName ?? "Untitled")
                    .foregroundStyle(cue.displayName == nil ? .tertiary : .secondary)
                    .opacity(stacking)
                Text(cue.displayName ?? "Untitled")
                    .foregroundStyle(rowNameStyle)
                    .opacity(1 - stacking)
            }
            .font(typography.cueName(size: nameSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(nameOpacity)

            CueIndicators(
                cue: cue,
                size: max(
                    CueRowView.Role.minimumIndicatorSize,
                    min(numberSize, CueRowView.Role.largestRowFontSize) * CueRowView.Role.indicatorSizeRatio
                )
            )
            .opacity(1 - stacking)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var rowNameStyle: AnyShapeStyle {
        guard cue.displayName != nil else { return AnyShapeStyle(.tertiary) }
        guard let color = cue.color else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color)
    }

    private var accessibilityDescription: String {
        var parts: [String] = stacking > 0.5 ? ["Standing by"] : []
        if let number = cue.displayNumber { parts.append("cue \(number)") }
        if let name = cue.displayName { parts.append(name) }
        parts.append(contentsOf: CueIndicators.accessibilityParts(for: cue))
        return parts.joined(separator: ", ")
    }
}

/// Places a number, name and indicators either inline, baselines aligned
/// and centred as a group, or stacked with the name centred under the
/// number, blending between the two by `stacking`. Its bounds are the
/// number's, so positioning the label positions the number.
///
/// Both arrangements are worked out at the sizes the cue has at each end of
/// the move, not its in-between size, and the name travels in a straight
/// line between them. Blending at the in-between size would carry the name
/// out past where it lands while the number is still growing.
private struct DrumLabelLayout: Layout {
    var stacking: CGFloat
    var maxWidth: CGFloat
    /// The row-end size over the current size, for the number and the name.
    var rowNumberScale: CGFloat = 1
    var rowNameScale: CGFloat = 1
    /// The standby-end size over the current size, likewise.
    var standbyNumberScale: CGFloat = 1
    var standbyNameScale: CGFloat = 1

    static let inlineSpacing: CGFloat = 12
    static let stackedSpacing: CGFloat = 8
    static let indicatorSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let number = subviews.first else { return .zero }
        return number.sizeThatFits(.unspecified)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        guard subviews.count == 3 else { return }
        let k = stacking

        let number = subviews[0].dimensions(in: .unspecified)
        let indicators = subviews[2].sizeThatFits(.unspecified)
        let indicatorRoom = indicators.width > 0 ? indicators.width + Self.indicatorSpacing : 0

        // The room the name has inline at the row end, converted back to the
        // name's current size, blending out to the full width as it stacks.
        let rowNumberWidth = number.width * rowNumberScale
        let inlineRoom = max(0, maxWidth - rowNumberWidth - Self.inlineSpacing - indicatorRoom) / rowNameScale
        let stackedRoom = max(0, maxWidth - indicatorRoom)
        let name = subviews[1].dimensions(
            in: ProposedViewSize(width: inlineRoom + (stackedRoom - inlineRoom) * k, height: nil)
        )

        // Inline, at the row end: the group is centred, so the number sits
        // left of centre, and the name shares the number's baseline.
        let rowName = CGSize(width: name.width * rowNameScale, height: name.height * rowNameScale)
        let rowNumberHeight = number.height * rowNumberScale
        let groupWidth = rowNumberWidth + Self.inlineSpacing + rowName.width + indicatorRoom
        let inlineNumberOffset = rowNumberWidth / 2 - groupWidth / 2
        let inlineNameOffset = CGSize(
            width: rowNumberWidth / 2 + Self.inlineSpacing + rowName.width / 2,
            height: number[VerticalAlignment.firstTextBaseline] * rowNumberScale
                - name[VerticalAlignment.firstTextBaseline] * rowNameScale
                + rowName.height / 2 - rowNumberHeight / 2
        )

        // Stacked, at the standby end: the name centred under the number.
        let stackedNameOffset = CGSize(
            width: 0,
            height: number.height * standbyNumberScale / 2
                + Self.stackedSpacing
                + name.height * standbyNameScale / 2
        )

        // Offsets from the label's centre, travelling straight between ends.
        let numberCentre = CGPoint(x: bounds.midX + inlineNumberOffset * (1 - k), y: bounds.midY)
        let nameCentre = CGPoint(
            x: numberCentre.x + inlineNameOffset.width * (1 - k) + stackedNameOffset.width * k,
            y: numberCentre.y + inlineNameOffset.height * (1 - k) + stackedNameOffset.height * k
        )

        subviews[0].place(at: numberCentre, anchor: .center, proposal: .unspecified)
        subviews[1].place(
            at: nameCentre, anchor: .center,
            proposal: ProposedViewSize(width: name.width, height: name.height)
        )
        subviews[2].place(
            at: CGPoint(x: nameCentre.x + name.width / 2 + Self.indicatorSpacing, y: nameCentre.y),
            anchor: .leading,
            proposal: .unspecified
        )
    }
}

private struct PlayheadArrow: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: "arrowtriangle.right.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

#Preview {
    CueListView()
        .environment(AppModel())
        .frame(width: 900, height: 560)
}

#Preview("Drum turning through a cue list") {
    @Previewable @State var playhead = 3

    var list = Cue(uniqueID: "list")
    list.children = (1...8).map { number in
        var cue = Cue(uniqueID: "\(number)")
        cue.number = "\(number * 10)"
        cue.name = "Cue number \(number * 10)"
        return cue
    }
    let graph = CueGraph(cueList: list)

    return CueDrum(graph: graph, standby: graph.rows[playhead], standbyIndex: playhead)
        .overlay(alignment: .topTrailing) {
            Button("GO") { playhead = (playhead + 1) % graph.rows.count }
                .padding()
        }
        .frame(width: 900, height: 560)
        .environment(AppModel())
}


