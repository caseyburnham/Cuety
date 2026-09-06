import SwiftUI

/// The headline display: the cue standing by at the playhead.
struct CueDisplayView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }
    private var typography: Typography { Typography(preferences: model.preferences) }

    var body: some View {
        VStack(spacing: 0) {
            if let cue = client.playheadCue {
                cueContent(cue)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.cueChange, value: client.currentPlayheadCueID)
    }

    // MARK: - Cue content

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
                    .transition(.blurReplace)
                    .id(cue.uniqueID)
            }

            if !model.isPresenting {
                DetailPillsRow(cue: cue, kinds: model.preferences.visiblePills)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The number fills the space when there is one; an unnumbered cue promotes
    /// its name into the headline slot rather than leaving it blank.
    @ViewBuilder
    private func numberOrName(_ cue: Cue) -> some View {
        if let number = cue.displayNumber {
            Text(number)
                .font(typography.cueNumber)
                // The base size is far larger than any window, so the scale
                // factor is what actually sizes the text. This is how the
                // number stays "as big as it can be" through resizes and
                // presentation mode without measuring anything by hand.
                .minimumScaleFactor(Typography.cueNumberMinimumScale)
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Cue number \(number)")
        } else if let name = cue.displayName {
            VStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 200, weight: .bold))
                    .minimumScaleFactor(0.05)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .transition(.blurReplace)

                Text("Unnumbered")
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .tracking(1.2)
            }
            .accessibilityLabel("Unnumbered cue, \(name)")
        } else {
            Text("—")
                .font(typography.cueNumber)
                .minimumScaleFactor(Typography.cueNumberMinimumScale)
                .lineLimit(1)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Cue with no number or name")
        }
    }

    private var standingByCaption: some View {
        HStack(spacing: 6) {
            Text("Standing By")
            if let graph = client.watchedGraph,
               let cueID = client.currentPlayheadCueID,
               graph.isLast(cueID) {
                Text("· End of List")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .fontWeight(.semibold)
        .textCase(.uppercase)
        .tracking(1.4)
        .foregroundStyle(.secondary)
    }

    // MARK: - Empty states
    //
    // Three genuinely different situations, each with its own explanation.
    // Collapsing them into one "no cue" message would leave the operator
    // guessing which one they are in.

    @ViewBuilder
    private var emptyState: some View {
        if !client.status.hasLiveData {
            ContentUnavailableView {
                Label("Not Connected", systemImage: client.status.systemImage)
            } description: {
                Text(client.status.detail)
            }
        } else if client.cueLists.isEmpty {
            ContentUnavailableView {
                Label("No Cue Lists", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This workspace has no cue lists.")
            }
        } else if client.watchedCueListID == nil {
            ContentUnavailableView {
                Label("No Cue List Selected", systemImage: "eye.slash")
            } description: {
                Text("Choose a cue list in the sidebar to watch its playhead.")
            }
        } else {
            // The playhead is genuinely unset: QLab sent a playbackPosition
            // update with no cue ID. A real state, not an error.
            VStack(spacing: 14) {
                Text("—")
                    .font(typography.cueNumber)
                    .minimumScaleFactor(Typography.cueNumberMinimumScale)
                    .lineLimit(1)
                    .foregroundStyle(.quaternary)

                Text("No Cue Standing By")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("The playhead in this cue list is not set.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(32)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No cue standing by. The playhead in this cue list is not set.")
        }
    }
}

#Preview {
    CueDisplayView()
        .environment(AppModel())
        .frame(width: 900, height: 500)
}
