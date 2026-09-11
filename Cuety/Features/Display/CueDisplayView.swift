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
            if let cue = liveCue {
                cueContent(cue)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.cueChange, value: client.currentPlayheadCueID)
    }

    /// The cue at the playhead, and only while the session is live enough for
    /// that to still be true.
    ///
    /// The client already discards its cue data on a drop, so this check is
    /// redundant today — deliberately. A stale cue captioned "Standing By" on
    /// a stage display is the worst thing this app can do, and the display
    /// should not be one refactor of the networking layer away from doing it
    /// again. The contract is enforced where it is visible.
    private var liveCue: Cue? {
        guard client.status.hasLiveData else { return nil }
        return client.playheadCue
    }

    /// The name of the cue list the given cue actually sits in.
    ///
    /// Looked up in the cue tree rather than read off the cue, because
    /// ``Cue/listName`` is the cue's own displayed name and not its list's.
    /// The watched list is checked first: it is where the playhead cue lives
    /// in every ordinary case, so the general search is the exception.
    private func cueListName(containing cue: Cue) -> String? {
        if let watchedID = client.watchedCueListID,
           let watched = client.cueLists.first(where: { $0.uniqueID == watchedID }),
           watched.children.firstCue(withID: cue.uniqueID) != nil {
            return watched.displayName
        }
        return client.cueLists.cueList(containing: cue.uniqueID)?.displayName
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
                DetailPillsRow(
                    cue: cue,
                    kinds: model.preferences.visiblePills,
                    cueListName: cueListName(containing: cue)
                )
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
    // Five genuinely different situations, each with its own explanation.
    // Collapsing them would leave the operator guessing which one they are in.
    // All are `ContentUnavailableView`, so "nothing to show" always looks the
    // same however Cuety got there.
    //
    // The three that used to be one message are the last three: a cue list
    // nobody has asked about yet, one whose playhead query failed, and one
    // that genuinely has nothing standing by. Only the last is "the playhead
    // is not set" — saying that about the other two claims knowledge Cuety
    // does not have, on a display whose whole job is being trustworthy.

    @ViewBuilder
    private var emptyState: some View {
        if !client.status.hasLiveData {
            // Presentation mode hides the toolbar, and with it the status
            // glyph that would otherwise be the operator's first sign of a
            // drop. `ContentUnavailableView` is metricked for a window someone
            // is sitting in front of, which is exactly not the case here, so
            // stage mode states the loss at its own scale instead.
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
            // The query failed. Cuety does not know where the playhead is,
            // which is emphatically not the same as knowing there is no cue
            // standing by — and this used to say the latter.
            ContentUnavailableView {
                Label("Playhead Unknown", systemImage: "questionmark.circle")
            } description: {
                Text("Cuety could not read the playhead of this cue list. \(reason)")
            }
        } else if client.watchedPlayhead == nil {
            // Asked for, not yet answered. A brief state during connection,
            // and a lasting one if a refresh was cancelled partway.
            ContentUnavailableView {
                Label("Waiting for QLab", systemImage: "progress.indicator")
            } description: {
                Text("Cuety has not heard back about this cue list's playhead yet.")
            }
        } else {
            // The playhead is genuinely unset: QLab answered, and nothing is
            // standing by. A real state, not an error.
            ContentUnavailableView {
                // The same glyph the drawer marks the playhead with.
                Label("No Cue Standing By", systemImage: "arrowtriangle.right")
            } description: {
                Text("The playhead in this cue list is not set.")
            }
        }
    }

    /// The connection state at stage-display scale.
    ///
    /// Sized to be read from wherever the display is being watched from, and
    /// tinted with the status's own colour so it cannot disagree with the
    /// toolbar glyph the operator sees on leaving presentation mode.
    private var presentedStatusState: some View {
        VStack(spacing: 24) {
            Image(systemName: client.status.systemImage)
                .font(.system(size: 96))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(client.status.tint)

            VStack(spacing: 10) {
                // The operator's chosen family, as the cue name uses: this is
                // standing in for the headline, not annotating it.
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

#Preview {
    CueDisplayView()
        .environment(AppModel())
        .frame(width: 900, height: 500)
}
