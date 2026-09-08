import SwiftUI

/// The headline display: the cue standing by at the playhead.
struct CueDisplayView: View {
    @Environment(AppModel.self) private var model

    /// The tracking applied to the display's small uppercase captions. One
    /// value, so the caption above the number and the one below it read as the
    /// same piece of typography.
    private static let captionTracking: CGFloat = 1.2

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
                    // The colour the operator gave the cue in QLab, so the
                    // colour-coding they already rely on carries through to the
                    // display instead of stopping at QLab's window.
                    .foregroundStyle(cue.color ?? .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .transition(.blurReplace)
                    .id(cue.uniqueID)
            }

            if !model.isPresenting {
                DetailPillsRow(cue: cue, kinds: model.preferences.visiblePills)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
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
                // The same font as a cue number: this name is standing in for
                // one, so it should not silently ignore the operator's choice
                // of family the way a hardcoded system font did.
                Text(name)
                    .font(typography.cueNumber)
                    .minimumScaleFactor(Typography.cueNumberMinimumScale)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    // Still the cue's colour, but against `.primary` rather
                    // than `.secondary`: here the name is the headline, so an
                    // uncoloured cue must not read as subordinate to nothing.
                    .foregroundStyle(cue.color ?? .primary)
                    .transition(.blurReplace)

                caption("Unnumbered")
                    .foregroundStyle(.tertiary)
            }
            .accessibilityLabel("Unnumbered cue, \(name)")
        } else {
            Text(verbatim: "—")
                .font(typography.cueNumber)
                .minimumScaleFactor(Typography.cueNumberMinimumScale)
                .lineLimit(1)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Cue with no number or name")
        }
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

    // MARK: - Empty states
    //
    // Three genuinely different situations, each with its own explanation.
    // Collapsing them into one "no cue" message would leave the operator
    // guessing which one they are in. All three are `ContentUnavailableView`, so
    // "nothing to show" always looks the same however Cuety got there.

    @ViewBuilder
    private var emptyState: some View {
        if !client.status.hasLiveData {
            ContentUnavailableView {
                Label(client.status.title, systemImage: client.status.systemImage)
            } description: {
                Text(client.status.detail)
            }
        } else if client.cueLists.isEmpty {
            ContentUnavailableView {
                Label("No Cue Lists", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This workspace has no cue lists.")
            }
        } else {
            // The playhead is genuinely unset: QLab sent a playbackPosition
            // update with no cue ID. A real state, not an error.
            ContentUnavailableView {
                // The same glyph the drawer marks the playhead with.
                Label("No Cue Standing By", systemImage: "arrowtriangle.right")
            } description: {
                Text("The playhead in this cue list is not set.")
            }
        }
    }
}

#Preview {
    CueDisplayView()
        .environment(AppModel())
        .frame(width: 900, height: 500)
}
