import SwiftUI

/// The cue list layout: the standby cue drawn as large as the display draws
/// it, beside a fixed playhead arrow, with its neighbours above and below.
/// On a go the rows turn like a drum.
struct CueListView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        if let graph = client.watchedGraph,
           let cueList = client.watchedCueList,
           let standby = model.standbyCue,
           let index = graph.rowIndex(of: standby.uniqueID) {
            CueDrum(
                graph: graph,
                rows: cueList.children,
                standby: standby,
                standbyIndex: index
            )
            .id(graph.cueListID)
#if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
#endif
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
    let rows: [Cue]
    let standby: Cue
    let standbyIndex: Int

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headlineSizingCache = HeadlineSizingCache()
    @State private var metricsCache = DrumMetricsCache()

    /// The row index the drum is turned to. It trails `standbyIndex` so the
    /// change can be animated, and is nil until the drum first appears.
    @State private var displayedOffset: Double?

    /// A jump further than this, such as the operator setting the playhead
    /// by hand, snaps rather than spinning the drum through every cue.
    static let maximumAnimatedJump = 3

    static let arrowSizeRatio: CGFloat = 0.3
    static let arrowSpacingRatio: CGFloat = 0.06
    static let horizontalPadding: CGFloat = 32
    static let pillsSpacing: CGFloat = 12

    private var typography: Typography { Typography(preferences: model.preferences) }

    private var pillSize: PillSize {
        horizontalSizeClass == .compact ? .small : model.preferences.pillSize
    }

    var body: some View {
        GeometryReader { proxy in
            let typography = self.typography
            let metrics = metrics(in: proxy.size, typography: typography)

            ZStack {
                DrumRows(
                    offset: displayedOffset ?? Double(standbyIndex),
                    rows: rows,
                    standby: standby,
                    standbyIndex: standbyIndex,
                    metrics: metrics,
                    typography: typography
                )

                if model.preferences.showsPlayhead {
                    let accent = model.preferences.playheadAccent.color(for: standby)
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: metrics.arrowSize))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                        .position(x: metrics.arrowX, y: metrics.numberCenterY)
                        .animation(animatesShift ? Motion.listShift : nil, value: accent)
                }

                // The pills hang from just below the standby name, so a
                // note or a wrapped row grows them downward without
                // moving the number, name or arrow.
                if model.preferences.showsDetailPills {
                    DetailPillsRow(
                        cue: standby,
                        kinds: model.preferences.visiblePills,
                        cueListName: model.client.watchedCueListName,
                        size: pillSize,
                        showsCueTypeLabel: model.preferences.showsCueTypeLabel,
                        performanceMode: model.preferences.performanceMode
                    )
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.top, metrics.pillsTop)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
        }
        .clipped()
        .background {
            (standby.color ?? .clear)
                .opacity(CueDisplayView.canvasTintOpacity)
                .ignoresSafeArea()
                .animation(animatesShift ? Motion.listShift : nil, value: standby.color)
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
    /// on a row of their own beneath the other pills. The pills' measured
    /// height is deliberately not used: feeding it back into the layout moved
    /// every cue on the drum while the pills were still animating.
    private var pillsHeight: CGFloat {
        guard model.preferences.showsDetailPills else { return 0 }
        let rows: CGFloat = model.preferences.visiblePills.contains(.notes) ? 2 : 1
        return pillSize.height * rows + pillSize.spacing * (rows - 1)
    }

    private var animatesShift: Bool {
        !model.preferences.performanceMode && !reduceMotion
    }

    /// Lays the standby position out the way the display does: the number
    /// fills what the name and pills leave, and the arrow sits beside the
    /// widest number in the list so it never has to move between cues.
    private func metrics(in size: CGSize, typography: Typography) -> DrumMetrics {
        let showsName = model.preferences.showsCueName
        let showsPlayhead = model.preferences.showsPlayhead
        let pillsHeight = self.pillsHeight
        let text = standby.displayNumber ?? "–"
        let reference = headlineSizingCache.referenceNumber(
            for: text,
            graph: graph,
            typography: typography
        )

        return metricsCache.metrics(
            size: size,
            reference: reference,
            typography: typography,
            showsName: showsName,
            showsPlayhead: showsPlayhead,
            pillsHeight: pillsHeight
        ) {
            let nameSize: CGFloat = min(28, max(17, size.height / 12))
            let padding = DrumMetrics.contentPadding
            let bandHeight = DrumMetrics.bandHeight(for: size.height)

            let nameBlock = showsName
                ? typography.lineHeight(size: nameSize) + DrumLabelLayout.stackedSpacing
                : 0
            let pillBlock = pillsHeight > 0 ? Self.pillsSpacing + pillsHeight : 0
            let available = max(0, size.height - bandHeight * 2 - DrumMetrics.previousCueExtraHeight - padding * 2)
            let numberHeight = max(0, available - nameBlock - pillBlock)
            let numberWidth = max(0, size.width - Self.horizontalPadding * 2)

            // Fit the number to the available height first. The arrow's size and
            // spacing scale with the number, so reserve that width algebraically
            // instead of subtracting space based on an already width-constrained fit.
            let firstFit = max(1, typography.cueNumberPointSize(
                fitting: reference,
                in: CGSize(width: numberWidth, height: numberHeight)
            ))

            // The arrow stays beside the widest cue number, so it holds still
            // as the playhead moves through the list.
            let arrowText = reference
            let widthPerPoint = typography.cueNumberWidth(of: arrowText, size: firstFit) / firstFit
            let widthLimitedSize = showsPlayhead
                ? numberWidth / (
                    widthPerPoint + 2 * (Self.arrowSizeRatio + Self.arrowSpacingRatio)
                )
                : numberWidth / widthPerPoint
            let numberSize = max(1, min(firstFit, widthLimitedSize))
            let arrowSize = numberSize * Self.arrowSizeRatio
            let referenceWidth = typography.cueNumberWidth(of: arrowText, size: numberSize)
            let arrowX = max(
                Self.horizontalPadding / 2 + arrowSize / 2,
                size.width / 2 - referenceWidth / 2 - numberSize * Self.arrowSpacingRatio - arrowSize / 2
            )

            // The number, name and pills are centred as one block, so the pills
            // sit under the name rather than against the cues below.
            let numberLineHeight = typography.lineHeight(size: numberSize)
            let blockHeight = numberLineHeight + nameBlock + pillBlock
            let blockTop = bandHeight + DrumMetrics.previousCueExtraHeight + padding + max(0, available - blockHeight) / 2

            return DrumMetrics(
                size: size,
                bandHeight: bandHeight,
                standbyNumberSize: numberSize,
                standbyNameSize: nameSize,
                showsStandbyName: showsName,
                numberCenterY: blockTop + numberLineHeight / 2,
                arrowSize: arrowSize,
                arrowX: arrowX,
                pillsTop: blockTop + numberLineHeight + nameBlock + Self.pillsSpacing
            )
        }
    }
}

@MainActor
private final class DrumMetricsCache {
    private struct Key: Equatable {
        let size: CGSize
        let reference: String
        let usesRounded: Bool
        let fontWeight: Font.Weight
        let showsName: Bool
        let showsPlayhead: Bool
        let pillsHeight: CGFloat
    }

    private var cachedKey: Key?
    private var cachedMetrics: DrumMetrics?

    func metrics(
        size: CGSize,
        reference: String,
        typography: Typography,
        showsName: Bool,
        showsPlayhead: Bool,
        pillsHeight: CGFloat,
        compute: () -> DrumMetrics
    ) -> DrumMetrics {
        let key = Key(
            size: size,
            reference: reference,
            usesRounded: typography.usesRounded,
            fontWeight: typography.cueNumberWeight,
            showsName: showsName,
            showsPlayhead: showsPlayhead,
            pillsHeight: pillsHeight
        )
        if cachedKey == key, let cachedMetrics {
            return cachedMetrics
        }
        let result = compute()
        cachedKey = key
        cachedMetrics = result
        return result
    }
}

/// Where and how large each position on the drum draws its cue. Position
/// zero is standby; negative positions are earlier cues, positive later.
struct DrumMetrics {
    static let rowPitch: CGFloat = 34
    static let bandPadding: CGFloat = 12
    static let previousCueExtraHeight: CGFloat = rowPitch
    static let contentPadding: CGFloat = 16
    static let minimumStandbyHeight: CGFloat = 160
    // Keep the neighbourhood alive beyond the viewport. Its visible row
    // count must never feed back into the space reserved for the main cue.
    static func bandHeight(for canvasHeight: CGFloat) -> CGFloat {
        min(
            CGFloat(CueLayout.listRowRadius) * rowPitch + bandPadding * 2,
            max(0, canvasHeight - minimumStandbyHeight - contentPadding * 2) / 4
        )
    }

    var lastPosition: Int { CueLayout.listRowRadius + 2 }

    let size: CGSize
    let bandHeight: CGFloat
    let standbyNumberSize: CGFloat
    let standbyNameSize: CGFloat
    let showsStandbyName: Bool
    let numberCenterY: CGFloat
    let arrowSize: CGFloat
    let arrowX: CGFloat
    let pillsTop: CGFloat

    private static func role(at position: Int) -> CueRowView.Role {
        position < 0 ? .above(distance: -position) : .below(distance: position)
    }

    func y(at position: Double) -> CGFloat {
        interpolate(position) { position in
            let distance = CGFloat(abs(position)) - 0.5
            if position == 0 {
                return numberCenterY
            } else if position < 0 {
                return bandHeight + Self.previousCueExtraHeight - Self.bandPadding - distance * Self.rowPitch
            } else {
                return size.height - bandHeight + Self.bandPadding + distance * Self.rowPitch
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
            if position <= -lastPosition || position >= CueLayout.listRowRadius + 1 { return 0 }
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
        let last = Double(lastPosition)
        let clamped = min(last, max(-last, position))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lastPosition, lower + 1)
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
@Animatable
private struct DrumRows: View {
    var offset: Double
    @AnimatableIgnored var rows: [Cue]
    @AnimatableIgnored var standby: Cue
    @AnimatableIgnored var standbyIndex: Int
    @AnimatableIgnored var metrics: DrumMetrics
    @AnimatableIgnored var typography: Typography

    var body: some View {
        let reach = Double(metrics.lastPosition)
        let first = max(-1, min(rows.count, Int((offset - reach).rounded(.down))))
        let last = max(-1, min(rows.count, Int((offset + reach).rounded(.up))))

        ZStack {
            if first <= last {
                ForEach(first...last, id: \.self) { index in
                    let position = Double(index) - offset
                    let y = metrics.y(at: position)
                    let opacity = metrics.opacity(at: position)
                    item(at: index, position: position)
                        .position(x: metrics.size.width / 2, y: y)
                        .opacity(opacity)
                        .accessibilityHidden(
                            y < 0 || y > metrics.size.height || opacity == 0
                        )
                }
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

            // Render text at the larger adjacent integer step's font size and
            // scale down smoothly on the GPU during fractional transitions so
            // CoreText never rasterizes intermediate font sizes per frame,
            // while resting integer positions render natively at 1:1 scale.
            let basePosition = trunc(position)

            // A standby cue inside a group stands in for the group's row.
            DrumLabel(
                cue: index == standbyIndex ? standby : rows[index],
                typography: typography,
                numberSize: metrics.numberSize(at: position),
                nameSize: metrics.nameSize(at: position),
                baseNumberSize: metrics.numberSize(at: basePosition),
                baseNameSize: metrics.nameSize(at: basePosition),
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
    let typography: Typography
    let numberSize: CGFloat
    let nameSize: CGFloat
    let baseNumberSize: CGFloat
    let baseNameSize: CGFloat
    let nameOpacity: CGFloat
    let stacking: CGFloat
    let maxWidth: CGFloat
    let rowNumberSize: CGFloat
    let rowNameSize: CGFloat
    let standbyNumberSize: CGFloat
    let standbyNameSize: CGFloat

    var body: some View {
        let resolvedNumberSize = max(1, numberSize)
        let resolvedNameSize = max(1, nameSize)
        let resolvedBaseNumberSize = max(1, baseNumberSize)
        let resolvedBaseNameSize = max(1, baseNameSize)
        let numberVisualScale = resolvedNumberSize / resolvedBaseNumberSize
        let nameVisualScale = resolvedNameSize / resolvedBaseNameSize

        let baseIndicatorSize = max(
            CueRowView.Role.minimumIndicatorSize,
            min(resolvedBaseNumberSize, CueRowView.Role.largestRowFontSize)
                * CueRowView.Role.indicatorSizeRatio
        )
        let targetIndicatorSize = max(
            CueRowView.Role.minimumIndicatorSize,
            min(resolvedNumberSize, CueRowView.Role.largestRowFontSize)
                * CueRowView.Role.indicatorSizeRatio
        )

        DrumLabelLayout(
            stacking: stacking,
            maxWidth: maxWidth,
            rowNumberScale: rowNumberSize / resolvedBaseNumberSize,
            rowNameScale: rowNameSize / resolvedBaseNameSize,
            standbyNumberScale: standbyNumberSize / resolvedBaseNumberSize,
            standbyNameScale: standbyNameSize / resolvedBaseNameSize,
            nameVisualScale: nameVisualScale
        ) {
            Text(cue.displayNumber ?? "–")
                .font(typography.cueNumber(size: resolvedBaseNumberSize))
                .monospacedDigit()
                .foregroundStyle(cue.displayNumber == nil ? .tertiary : .primary)
                .lineLimit(1)
                .fixedSize()
                .scaleEffect(numberVisualScale)

            nameLabel
                .font(typography.font(size: resolvedBaseNameSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .scaleEffect(nameVisualScale)
                .opacity(nameOpacity)

            CueIndicators(cue: cue, size: baseIndicatorSize)
                .scaleEffect(targetIndicatorSize / baseIndicatorSize)
                .opacity(1 - stacking)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var nameLabel: some View {
        let displayName = cue.displayName
        let title = Text(displayName ?? "Untitled")
        if let color = cue.color, displayName != nil {
            ZStack {
                title
                    .foregroundStyle(.secondary)
                    .opacity(stacking)
                title
                    .foregroundStyle(color)
                    .opacity(1 - stacking)
            }
        } else {
            title.foregroundStyle(displayName == nil ? .tertiary : .secondary)
        }
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
    /// The row-end size over the measured base size, for the number and the name.
    var rowNumberScale: CGFloat = 1
    var rowNameScale: CGFloat = 1
    /// The standby-end size over the measured base size, likewise.
    var standbyNumberScale: CGFloat = 1
    var standbyNameScale: CGFloat = 1
    /// The name's current visual scale relative to its measured base size.
    var nameVisualScale: CGFloat = 1

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

        // The room the name has inline at the row end and stacked at the
        // standby end, both converted into the name's measured base size.
        let rowNumberWidth = number.width * rowNumberScale
        let inlineRoom = max(0, maxWidth - rowNumberWidth - Self.inlineSpacing - indicatorRoom) / rowNameScale
        let stackedRoom = max(0, maxWidth - indicatorRoom) / standbyNameScale
        let name = subviews[1].dimensions(
            in: ProposedViewSize(width: inlineRoom + (stackedRoom - inlineRoom) * k, height: nil)
        )

        // Inline, at the row end: the number and name are centred as a
        // group, so the number sits left of centre, and the name shares the
        // number's baseline. The indicators hang off the end rather than
        // joining the group, since they come and go as a cue is fired and
        // loaded, and would otherwise jolt the whole row sideways.
        let rowName = CGSize(width: name.width * rowNameScale, height: name.height * rowNameScale)
        let rowNumberHeight = number.height * rowNumberScale
        let groupWidth = rowNumberWidth + Self.inlineSpacing + rowName.width
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
            at: CGPoint(
                x: nameCentre.x + name.width * nameVisualScale / 2 + Self.indicatorSpacing,
                y: nameCentre.y
            ),
            anchor: .leading,
            proposal: .unspecified
        )
    }
}

#Preview {
    CueListView()
        .environment(AppModel.preview)
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

    return CueDrum(
        graph: graph,
        rows: list.children,
        standby: list.children[playhead],
        standbyIndex: playhead
    )
        .overlay(alignment: .topTrailing) {
            Button("GO") { playhead = (playhead + 1) % graph.rowIDs.count }
                .padding()
        }
        .frame(width: 900, height: 560)
        .environment(AppModel.preview)
}
