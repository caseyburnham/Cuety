import SwiftUI

struct CueDisplayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var headlineSizingCache = HeadlineSizingCache()

    private static let captionTracking: CGFloat = 1.2
    private static let canvasTintOpacity: Double = 0.18

    private var client: QLabClient { model.client }
    private var typography: Typography { Typography(preferences: model.preferences) }

    var body: some View {
        VStack(spacing: 0) {
            if model.isDataStale {
                staleDataState
            } else if let cue = client.liveCue {
                cueContent(cue)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Washing the cue color across the canvas keeps it readable even when
        // the cue name is hidden. Clear stands in for "no color" so the tint
        // cross-fades with the cue change instead of popping in and out.
        .background((canvasTint ?? .clear).opacity(Self.canvasTintOpacity))
        // Performance mode disables the container animation; normal mode
        // retains the animated number transition and display resizing.
        .motion(
            Motion.cueChange,
            value: model.preferences.performanceMode
                ? nil
                : client.currentPlayheadCueID
        )
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var staleDataState: some View {
        ContentUnavailableView {
            Label("Data May Be Stale", systemImage: "clock.badge.exclamationmark")
        } description: {
            Text("Cuety keeps its connection policy while this scene is suspended. Return to the foreground to confirm the current cue from QLab.")
        }
    }

    private var detailPillSize: PillSize {
        horizontalSizeClass == .compact ? .small : model.preferences.pillSize
    }

    /// The live cue's color, or nil when the display is not showing a cue.
    private var canvasTint: Color? {
        guard !model.isDataStale else { return nil }
        return client.liveCue?.color
    }

    private func cueListName(containing cue: Cue) -> String? {
        if let watchedID = client.watchedCueListID,
           let watched = client.cueLists.first(where: { $0.uniqueID == watchedID }),
           client.watchedGraph?.cue(withID: cue.uniqueID) != nil {
            return watched.displayName
        }
        return client.cueLists.cueList(containing: cue.uniqueID)?.displayName
    }


    @ViewBuilder
    private func cueContent(_ cue: Cue) -> some View {
        VStack(spacing: model.isPresenting ? 12 : 8) {
            if !model.isPresenting {
                standingByCaption
            }

            numberOrName(cue)

            if model.preferences.showsCueName, cue.displayNumber != nil,
               let name = cue.displayName {
                Text(name)
                    .font(typography.cueName(size: model.isPresenting ? 40 : 28))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .transition(reduceMotion ? .identity : .opacity)
                    .id(cue.uniqueID)
            }

            if !model.isPresenting {
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
        if let number = cue.displayNumber {
            headline(number)
                // Keep the native numeric transition, but composite it on the GPU.
                .environment(\.contentTransitionAddsDrawingGroup, true)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(
                    model.preferences.performanceMode || reduceMotion ? .identity : .numericText()
                )
                .accessibilityLabel("Cue number \(number)")
        } else if let name = cue.displayName {
            VStack(spacing: 6) {
                Text(name)
                    .font(typography.cueNumber)
                    .minimumScaleFactor(Typography.cueNumberMinimumScale)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .transition(reduceMotion ? .identity : .opacity)

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

    private func headline(_ text: String) -> some View {
        let reference = referenceNumber(for: text)

        return GeometryReader { geometry in
            Text(text)
                .font(typography.cueNumber(
                    size: typography.cueNumberPointSize(fitting: reference, in: geometry.size)
                ))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func referenceNumber(for text: String) -> String {
        headlineSizingCache.referenceNumber(
            for: text,
            cueNumbers: client.watchedGraph?.cueNumbers ?? [],
            typography: typography
        )
    }

    private var standingByCaption: some View {
        HStack(spacing: 6) {
            caption("Standing By")
            if let graph = client.watchedGraph,
               let cueID = client.currentPlayheadCueID,
               graph.isLast(cueID) {
                caption("· End of List")
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
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
            if model.isPresenting {
                presentedStatusState
            } else {
                ContentUnavailableView {
                    Label(client.status.title, systemImage: client.status.systemImage)
                } description: {
                    Text(client.status.detail)
                }
            }
        } else if client.cueLists.isEmpty {
            ContentUnavailableView {
                Label("No Cue Lists", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This workspace has no cue lists.")
            }
        } else if client.watchedCueListID == nil {
            ContentUnavailableView {
                Label("No Cue List Selected", systemImage: "list.triangle")
            } description: {
                Text("Choose a cue list in the sidebar to follow its playhead.")
            }
        } else if case .unknown(let reason) = client.watchedPlayhead {
            ContentUnavailableView {
                Label("Playhead Unknown", systemImage: "questionmark.circle")
            } description: {
                Text("Cuety could not read the playhead of this cue list. \(reason)")
            }
        } else if client.watchedPlayhead == nil {
            ContentUnavailableView {
                Label("Waiting for QLab", systemImage: "progress.indicator")
            } description: {
                Text("Cuety has not heard back about this cue list's playhead yet.")
            }
        } else {
            ContentUnavailableView {
                Label("No Cue Standing By", systemImage: "arrowtriangle.right")
            } description: {
                Text("The playhead in this cue list is not set.")
            }
        }
    }

    private var presentedStatusState: some View {
        VStack(spacing: 24) {
            Image(systemName: client.status.systemImage)
                .font(.system(size: 96))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(client.status.tint)

            VStack(spacing: 10) {
                Text(client.status.title)
                    .font(typography.cueName(size: 48))
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)

                Text(client.status.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
            }
            .multilineTextAlignment(.center)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(client.status.title). \(client.status.detail)")
    }
}

@MainActor
private final class HeadlineSizingCache {
    private struct Inputs: Equatable {
        let cueNumbers: [String]
        let usesRounded: Bool
        let fontWeight: Font.Weight
    }

    private var inputs: Inputs?
    private var cachedListReference: String?

    func referenceNumber(for text: String, cueNumbers: [String], typography: Typography) -> String {
        let inputs = Inputs(
            cueNumbers: cueNumbers,
            usesRounded: typography.usesRounded,
            fontWeight: typography.cueNumberWeight
        )

        if self.inputs != inputs {
            cachedListReference = typography.widestCueNumber(among: cueNumbers)
            self.inputs = inputs
        }

        guard let cachedListReference else { return text }
        return typography.widestCueNumber(among: [cachedListReference, text]) ?? text
    }
}

#Preview {
    CueDisplayView()
        .environment(AppModel())
        .frame(width: 900, height: 500)
}
