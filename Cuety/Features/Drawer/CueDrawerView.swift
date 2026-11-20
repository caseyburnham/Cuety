import SwiftUI

struct CueDrawerView: View {
    let availableHeight: CGFloat

    @Environment(AppModel.self) private var model

    @State private var dragStartStep = 0
    @State private var isResizing = false
    @State private var numberWidthCache = DrawerNumberWidthCache()

    private var client: QLabClient { model.client }

    static let maxHeightShare: CGFloat = 0.45
    static let handleHeight: CGFloat = 22
    // This is a conservative row pitch. It includes the small spacing between
    // rows so every snapped step fits without needing a scrolling fallback.
    static let estimatedRowHeight: CGFloat = 33

    static func height(atStep step: Int) -> CGFloat {
        handleHeight + 24 + CGFloat(max(0, step * 2)) * estimatedRowHeight
    }

    static func stepsFitting(_ height: CGFloat) -> Int {
        let available = max(0, height * maxHeightShare - Self.height(atStep: 0))
        return max(
            Preferences.Limits.drawerRows.lowerBound,
            min(
                Preferences.Limits.drawerRows.upperBound,
                Int(available / (estimatedRowHeight * 2))
            )
        )
    }

    static func viewportHeight(availableHeight: CGFloat, step: Int) -> CGFloat {
        guard step > 0 else { return handleHeight }
        return min(
            availableHeight * maxHeightShare,
            height(atStep: step)
        )
    }

    private var maximumStep: Int {
        Self.stepsFitting(availableHeight)
    }

    private var isCollapsed: Bool { model.drawerStep == 0 }

    /// Gives the safe-area inset an explicit height for the selected step.
    /// Without this, the inset is content-sized and the drag only changes how
    /// many rows fit inside a view that remains at its maximum height.
    private var drawerHeight: CGFloat {
        // Keep the requested row stack alive outside the viewport. When a
        // window is too short to show every row, clipping reveals the rows
        // progressively as the window grows instead of changing the stack at
        // a height threshold.
        Self.viewportHeight(
            availableHeight: availableHeight,
            step: model.drawerStep
        )
    }

    private var playheadColor: Color {
        model.preferences.playheadAccent.color(for: model.standbyCue)
    }

    var body: some View {
        if model.hasCurrentCueData,
           client.watchedGraph != nil,
           client.currentPlayheadCueID != nil {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            drawerHandle

            if !isCollapsed,
               let graph = client.watchedGraph,
               let cueList = client.watchedCueList,
               let playheadID = client.currentPlayheadCueID {
                // Render the full requested neighbourhood even when the current
                // window cannot display it all. The drawer's clipping viewport
                // controls visibility, so rows can slide into view from beyond
                // its edges during a resize.
                let step = model.drawerStep
                let neighbourhood = graph.neighbourhood(
                    around: playheadID,
                    above: step,
                    below: step
                )
                let above = neighbourhood.above.compactMap {
                    graph.cue(withID: $0, in: cueList)
                }
                let below = neighbourhood.below.compactMap {
                    graph.cue(withID: $0, in: cueList)
                }

                rows(
                    graph: graph,
                    cueList: cueList,
                    playheadID: playheadID,
                    above: above,
                    below: below
                )
            }
        }
        .frame(height: drawerHeight, alignment: .top)
        .clipped()
        .overlay(alignment: .top) {
            Divider()
        }
        .background {
            (model.standbyCue?.color ?? .clear)
                .opacity(CueDisplayView.canvasTintOpacity)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cue list around the playhead")
    }

    private var drawerHandle: some View {
        HStack {
            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 38, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isResizing {
                        isResizing = true
                        dragStartStep = model.drawerStep
                    }

                    let rowPitch = Self.estimatedRowHeight * 2
                    let proposedStep = dragStartStep - Int((value.translation.height / rowPitch).rounded())
                    model.resizeDrawer(toStep: min(maximumStep, max(0, proposedStep)))
                }
                .onEnded { _ in
                    isResizing = false
                    dragStartStep = model.drawerStep
                }
        )
        .onTapGesture {
            if isCollapsed {
                model.resizeDrawer(toStep: min(1, maximumStep))
            }
        }
        #if os(macOS)
        .pointerStyle(.rowResize)
        #endif
        .accessibilityElement()
        .accessibilityLabel("Cue drawer")
        .accessibilityValue(drawerAccessibilityValue)
        .accessibilityHint("Adjust to show more or fewer cues on each side")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                model.resizeDrawer(toStep: min(maximumStep, model.drawerStep + 1))
            case .decrement:
                model.resizeDrawer(toStep: max(0, model.drawerStep - 1))
            @unknown default:
                break
            }
        }
    }

    private var drawerAccessibilityValue: String {
        let step = min(model.drawerStep, maximumStep)
        switch step {
        case 0: return "Collapsed"
        case 1: return "1 cue on each side"
        default: return "\(step) cues on each side"
        }
    }

    @ViewBuilder
    private func rows(
        graph: CueGraph, cueList: Cue, playheadID: String, above: [Cue], below: [Cue]
    ) -> some View {
        let typography = Typography(preferences: model.preferences)
        let numberWidth = numberWidthCache.width(
            graphID: graph.graphID,
            numbersVersion: graph.numbersVersion,
            playheadID: playheadID,
            step: model.drawerStep,
            above: above,
            below: below,
            typography: typography
        )
        let containingGroup = graph.containingRowID(of: playheadID).flatMap {
            graph.cue(withID: $0, in: cueList)
        }

        let stack = VStack(alignment: .leading, spacing: 2) {
            if graph.isFirst(playheadID) {
                boundaryRow("Top of cue list", systemImage: "arrow.up.to.line")
            } else {
                ForEach(above.enumerated(), id: \.element.id) { offset, cue in
                    CueRowView(
                        cue: cue,
                        role: .above(distance: above.count - offset),
                        typography: typography,
                        numberColumnWidth: numberWidth
                    )
                    .equatable()
                }
            }

            playheadMarker(insideGroup: containingGroup)

            if graph.isLast(playheadID) {
                boundaryRow("End of cue list", systemImage: "arrow.down.to.line")
            } else {
                ForEach(below.enumerated(), id: \.element.id) { offset, cue in
                    CueRowView(
                        cue: cue,
                        role: .below(distance: offset + 1),
                        typography: typography,
                        numberColumnWidth: numberWidth
                    )
                    .equatable()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)

        // Keep the rows intrinsic, then center the full stack in the
        // viewport. Rows that do not fit remain outside the clipped edges,
        // while the playhead stays in a stable position.
        stack
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .center)
    }

    private func playheadMarker(insideGroup group: Cue?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(playheadColor)

            if let group {
                Text("in \(group.displayName ?? "Untitled")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Rectangle()
                .fill(playheadColor.opacity(0.5))
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

struct CueRowView: View, Equatable {
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
    let typography: Typography

    /// Shared by the rows beside this one; nil measures only this row.
    var numberColumnWidth: CGFloat?

    /// The narrowest the number column gets, so a short number does not
    /// pull the names left.
    static let numberPlaceholder = "000.0"

    var body: some View {
        let states = CueState.states(of: cue)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            numberColumn
                .foregroundStyle(cue.displayNumber == nil ? .tertiary : .primary)

            Text(cue.displayName ?? "Untitled")
                .font(typography.font(
                    size: role.fontSize * Role.nameSizeRatio, weight: role.weight
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(nameStyle)

            Spacer(minLength: 0)

            CueIndicators(
                states: states,
                size: max(Role.minimumIndicatorSize, role.fontSize * Role.indicatorSizeRatio)
            )
        }
        .opacity(role.opacity)
        .contentTransition(.identity)
        .padding(.vertical, role.isFocalRow ? 3 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(states: states))
    }

    private var nameStyle: AnyShapeStyle {
        guard cue.displayName != nil else { return AnyShapeStyle(.tertiary) }
        guard let color = cue.color else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(color)
    }

    private var numberColumn: some View {
        Text(cue.displayNumber ?? "–")
            .font(typography.font(size: role.fontSize, weight: role.weight))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: resolvedNumberColumnWidth, alignment: .trailing)
    }

    private var resolvedNumberColumnWidth: CGFloat {
        if let numberColumnWidth { return numberColumnWidth }
        let placeholder = typography.drawerNumberWidth(
            of: Self.numberPlaceholder, size: Role.largestRowFontSize, weight: .semibold
        )
        let own = cue.displayNumber.map {
            typography.drawerNumberWidth(of: $0, size: role.fontSize, weight: role.weight)
        } ?? 0
        return max(placeholder, own)
    }

    private func accessibilityDescription(states: [CueState]) -> String {
        var parts = [role.accessibilityPrefix]
        if let number = cue.displayNumber { parts.append("cue \(number)") }
        if let name = cue.displayName { parts.append(name) }
        parts.append(contentsOf: states.map(\.spokenDescription))
        return parts.joined(separator: ", ")
    }
}

/// The glyphs a cue row shows for a cue QLab will treat specially.
struct CueIndicators: View, Equatable {
    let states: [CueState]
    let size: CGFloat

    init(states: [CueState], size: CGFloat) {
        self.states = states
        self.size = size
    }

    init(cue: Cue, size: CGFloat) {
        self.states = CueState.states(of: cue)
        self.size = size
    }

    static func accessibilityParts(for cue: Cue) -> [String] {
        CueState.states(of: cue).map(\.spokenDescription)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(states) { state in
                Image(systemName: state.systemImage)
                    .rotationEffect(state.rotation)
                    .foregroundStyle(state.tint)
                    .help(state.help)
            }
        }
        .font(.system(size: size))
    }
}

#Preview {
    CueDrawerView(availableHeight: 560)
        .environment(AppModel.preview)
        .frame(width: 900)
}

#Preview("Drawer at the tallest step a window allows") {
    func cue(_ number: Int) -> Cue {
        var cue = Cue(uniqueID: "\(number)")
        cue.number = "\(number)"
        cue.name = "Cue number \(number)"
        return cue
    }

    let height: CGFloat = 560
    let step = CueDrawerView.stepsFitting(height)
    let typography = Typography(preferences: AppModel.preview.preferences)

    return VStack(spacing: 0) {
        Text("42")
            .font(.system(size: 160, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(1...step, id: \.self) {
                    CueRowView(
                        cue: cue($0),
                        role: .above(distance: step + 1 - $0),
                        typography: typography
                    )
                }
                Rectangle().fill(.tint.opacity(0.5))
                    .frame(height: 1).padding(.vertical, 5)
                ForEach(1...step, id: \.self) {
                    CueRowView(
                        cue: cue($0 + step),
                        role: .below(distance: $0),
                        typography: typography
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(.thinMaterial)
    }
    .frame(width: 900, height: height)
    .environment(AppModel.preview)
}

#Preview("Awkward cue numbers") {
    let numbers = ["1", "12.5", "100.25", "A12", "1.1.1", "SQ-104"]
    let typography = Typography(preferences: AppModel.preview.preferences)

    return VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(numbers.enumerated()), id: \.offset) { offset, number in
            var cue = Cue(uniqueID: number)
            cue.number = number
            cue.name = "Cue named \(number)"
            return CueRowView(cue: cue, role: .below(distance: offset + 1), typography: typography)
        }
    }
    .padding(20)
    .frame(width: 420)
    .environment(AppModel.preview)
}

@MainActor
private final class DrawerNumberWidthCache {
    private struct Key: Equatable {
        let graphID: UUID
        let numbersVersion: UInt64
        let playheadID: String
        let step: Int
        let usesRounded: Bool
    }

    private struct MeasurementKey: Hashable {
        let text: String
        let size: CGFloat
        let weight: Font.Weight
    }

    private static let maxMeasuredWidthEntries = 2048

    private var cachedKey: Key?
    private var cachedWidth: CGFloat?
    private var measurementUsesRounded: Bool?
    private var measuredWidths: [MeasurementKey: CGFloat] = [:]

    func width(
        graphID: UUID,
        numbersVersion: UInt64,
        playheadID: String,
        step: Int,
        above: [Cue],
        below: [Cue],
        typography: Typography
    ) -> CGFloat {
        let key = Key(
            graphID: graphID,
            numbersVersion: numbersVersion,
            playheadID: playheadID,
            step: step,
            usesRounded: typography.usesRounded
        )
        if cachedKey == key, let cachedWidth {
            return cachedWidth
        }

        var measured = measuredWidth(
            of: CueRowView.numberPlaceholder,
            size: CueRowView.Role.largestRowFontSize,
            weight: .semibold,
            typography: typography
        )

        func include(_ cue: Cue, as role: CueRowView.Role) {
            guard let number = cue.displayNumber else { return }
            measured = max(measured, measuredWidth(
                of: number, size: role.fontSize, weight: role.weight, typography: typography
            ))
        }

        for (offset, cue) in above.enumerated() {
            include(cue, as: .above(distance: above.count - offset))
        }
        for (offset, cue) in below.enumerated() {
            include(cue, as: .below(distance: offset + 1))
        }

        cachedKey = key
        cachedWidth = measured
        return measured
    }

    private func measuredWidth(
        of text: String,
        size: CGFloat,
        weight: Font.Weight,
        typography: Typography
    ) -> CGFloat {
        if measurementUsesRounded != typography.usesRounded {
            measuredWidths.removeAll(keepingCapacity: true)
            measurementUsesRounded = typography.usesRounded
        }

        let key = MeasurementKey(text: text, size: size, weight: weight)
        if let cached = measuredWidths[key] {
            return cached
        }

        if measuredWidths.count >= Self.maxMeasuredWidthEntries {
            measuredWidths.removeAll(keepingCapacity: true)
        }
        let width = typography.drawerNumberWidth(of: text, size: size, weight: weight)
        measuredWidths[key] = width
        return width
    }
}
