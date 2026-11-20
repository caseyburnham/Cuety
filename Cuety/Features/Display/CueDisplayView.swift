import SwiftUI

struct CueDisplayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headlineSizingCache = HeadlineSizingCache()

    private static let captionTracking: CGFloat = 1.2
    static let canvasTintOpacity: Double = 0.18

    private var client: QLabClient { model.client }
    private var typography: Typography { Typography(preferences: model.preferences) }
    private var animatesCueChange: Bool { !model.preferences.performanceMode && !reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            if model.isDataStale {
                staleDataState
            } else if let cue = model.standbyCue {
                cueContent(cue)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Washing the cue color across the canvas keeps it readable even when
        // the cue name is hidden. Updating it immediately avoids forcing the
        // translucent toolbar overlay and Liquid Glass pills to resample an
        // animating full-window backdrop across frames.
        .background {
            (canvasTint ?? .clear)
                .opacity(Self.canvasTintOpacity)
                .ignoresSafeArea()
        }
    }

    private var staleDataState: some View {
        ContentUnavailableView {
            Label("Data May Be Stale", systemImage: "clock.badge.exclamationmark")
        } description: {
            Text(model.foregroundRefreshTask == nil
                 ? "Return to Cuety to confirm the current cue."
                 : "Refreshing cue data from QLab…")
        }
    }

    private var detailPillSize: PillSize {
        horizontalSizeClass == .compact ? .small : model.preferences.pillSize
    }

    /// The live cue's color, or nil when the display is not showing a cue.
    private var canvasTint: Color? {
        model.standbyCue?.color
    }

    private func cueListName(containing cue: Cue) -> String? {
        if client.watchedGraph?.rowIndex(of: cue.uniqueID) != nil {
            return client.watchedCueListName
        }
        return client.cueListName(containing: cue.uniqueID)
    }

    @ViewBuilder
    private func cueContent(_ cue: Cue) -> some View {
        VStack(spacing: 8) {
            if client.watchedGraph?.isLast(cue.uniqueID) == true {
                caption("End of List")
                    .foregroundStyle(.tertiary)
            }

            numberOrName(cue)

            if model.preferences.showsCueName, cue.displayNumber != nil,
               let name = cue.displayName {
                Text(name)
                    .font(typography.font(size: 28))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
            }

            if model.preferences.showsDetailPills {
                DetailPillsRow(
                    cue: cue,
                    kinds: model.preferences.visiblePills,
                    cueListName: cueListName(containing: cue),
                    size: detailPillSize,
                    showsCueTypeLabel: model.preferences.showsCueTypeLabel,
                    performanceMode: model.preferences.performanceMode
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func numberOrName(_ cue: Cue) -> some View {
        Group {
            if let number = cue.displayNumber {
                headline(number, animatesNumericTransition: animatesCueChange)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Cue number \(number)")
            } else if let name = cue.displayName {
                VStack(spacing: 6) {
                    Text(name)
                        .font(typography.cueNumber)
                        .minimumScaleFactor(Typography.cueNumberMinimumScale)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)

                    caption("Unnumbered")
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Unnumbered cue, \(name)")
            } else {
                headline("—")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Cue with no number or name")
            }
        }
        .animation(animatesCueChange ? Motion.cueChange : nil, value: cue.displayNumber == nil)
    }

    private func headline(_ text: String, animatesNumericTransition: Bool = false) -> some View {
        let reference = referenceNumber(for: text)

        return GeometryReader { geometry in
            let pointSize = headlineSizingCache.pointSize(
                for: reference,
                in: geometry.size,
                typography: typography
            )
            Text(text)
                .modifier(AnimatedCueNumberFont(
                    typography: typography,
                    pointSize: pointSize
                ))
                .monospacedDigit()
                .lineLimit(1)
                // Keep the native numeric transition GPU-accelerated so giant
                // display numerals don't re-rasterize on the CPU each frame.
                .environment(\.contentTransitionAddsDrawingGroup, animatesNumericTransition)
                .contentTransition(animatesNumericTransition ? .numericText() : .identity)
                .animation(reduceMotion ? nil : Motion.displayResize, value: pointSize)
                .animation(animatesNumericTransition ? Motion.cueChange : nil, value: text)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func referenceNumber(for text: String) -> String {
        headlineSizingCache.referenceNumber(
            for: text,
            graph: client.watchedGraph,
            typography: typography
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(Self.captionTracking)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !client.status.hasLiveData {
            ContentUnavailableView {
                Label(client.status.title, systemImage: client.status.systemImage)
            } description: {
                Text(client.status.detail)
            }
        } else if client.cueListSummaries.isEmpty {
            ContentUnavailableView {
                Label("No Cue Lists", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This workspace has no cue lists.")
            }
        } else if client.watchedCueListID == nil {
            ContentUnavailableView {
                Label("No Cue List Selected", systemImage: "text.line.first.and.arrowtriangle.forward")
            } description: {
                Text("Choose a cue list in the sidebar.")
            }
        } else if client.isWatchingCueCart {
            ContentUnavailableView {
                Label("Cue Cart", systemImage: "square.grid.3x3")
            } description: {
                Text("Cue carts have no playhead. Choose a cue list in the sidebar.")
            }
        } else if case .unknown(let reason) = client.watchedPlayhead {
            ContentUnavailableView {
                Label("Playhead Unknown", systemImage: "questionmark.circle")
            } description: {
                Text("Could not read the playhead of this cue list. \(reason)")
            }
        } else if client.watchedPlayhead == nil {
            ContentUnavailableView {
                Label("Waiting for QLab", systemImage: "progress.indicator")
            } description: {
                Text("Playhead details not received yet.")
            }
        } else {
            ContentUnavailableView {
                Label("No Cue Standing By", systemImage: "arrowtriangle.right")
            } description: {
                Text("The playhead in this cue list is not set.")
            }
        }
    }

}

@MainActor
private struct AnimatedCueNumberFont: AnimatableModifier {
    let typography: Typography
    var pointSize: CGFloat

    var animatableData: CGFloat {
        get { pointSize }
        set { pointSize = newValue }
    }

    func body(content: Content) -> some View {
        content.font(typography.cueNumber(size: pointSize))
    }
}

@MainActor
final class HeadlineSizingCache {
    private struct GraphInputs: Equatable {
        let graphID: UUID?
        let numbersVersion: UInt64
        let usesRounded: Bool
        let fontWeight: Font.Weight
    }

    private struct SizeInputs: Equatable {
        let text: String
        let space: CGSize
        let usesRounded: Bool
        let fontWeight: Font.Weight
    }

    private var graphInputs: GraphInputs?
    private var cachedListReference: String?
    private var cachedCueNumbers: Set<String> = []
    private var lastReferenceText: String?
    private var lastResolvedReference: String?

    private var lastSizeInputs: SizeInputs?
    private var lastPointSize: CGFloat?

    func pointSize(for text: String, in space: CGSize, typography: Typography) -> CGFloat {
        guard space.width > 0, space.height > 0, !text.isEmpty else {
            // Split-view transitions can briefly provide invalid geometry. Keep
            // the last stable size instead of falling to Typography's minimum.
            return lastPointSize ?? Typography.cueNumberBaseSize
        }

        let sizeInputs = SizeInputs(
            text: text,
            space: space,
            usesRounded: typography.usesRounded,
            fontWeight: typography.cueNumberWeight
        )
        if lastSizeInputs == sizeInputs, let lastPointSize {
            return lastPointSize
        }

        let pointSize = typography.cueNumberPointSize(fitting: text, in: space)
        lastSizeInputs = sizeInputs
        lastPointSize = pointSize
        return pointSize
    }

    func referenceNumber(for text: String, graph: CueGraph?, typography: Typography) -> String {
        let inputs = GraphInputs(
            graphID: graph?.graphID,
            numbersVersion: graph?.numbersVersion ?? 0,
            usesRounded: typography.usesRounded,
            fontWeight: typography.cueNumberWeight
        )

        if graphInputs != inputs {
            cachedListReference = graph.flatMap { typography.widestCueNumber(among: $0.cueNumbers) }
            cachedCueNumbers = graph.map { Set($0.cueNumbers) } ?? []
            graphInputs = inputs
            lastReferenceText = nil
            lastResolvedReference = nil
        }

        if lastReferenceText == text, let lastResolvedReference {
            return lastResolvedReference
        }

        let resolved: String
        if let cachedListReference {
            if cachedListReference == text || cachedCueNumbers.contains(text) {
                resolved = cachedListReference
            } else {
                resolved = typography.widestCueNumber(among: [cachedListReference, text]) ?? text
            }
        } else {
            resolved = text
        }

        lastReferenceText = text
        lastResolvedReference = resolved
        return resolved
    }
}

#Preview {
    CueDisplayView()
        .environment(AppModel.preview)
        .frame(width: 900, height: 500)
}
