import AppKit
import Observation

/// The Dock tile's badge, following the cue standing by.
///
/// `badgeLabel` rather than a drawn tile, deliberately. AppKit will hand over
/// the whole tile — `NSApplication/applicationIconImage` or
/// `NSDockTile/contentView` — and either one would let Cuety draw the cue
/// number at icon scale. Both also throw away everything `cuety-icon.icon`
/// provides: the layered treatment, the light, dark and tinted variants, and
/// the system's own icon shape. A badge keeps the real icon and adds the one
/// piece of information that is wanted, which is the trade the operator would
/// make if asked.
@MainActor
final class DockBadge {
    /// The observation loop, held so that ``follow(_:)`` is idempotent and so
    /// the badge can be given back.
    private var task: Task<Void, Never>?

    /// Badges the Dock tile with whatever `label` produces, and keeps doing so.
    ///
    /// Pushed rather than pulled, because the Dock tile is not a view: nothing
    /// redraws it when the playhead moves, so something has to notice and tell
    /// it. `Observations` is that something, and it is worth using over a
    /// hand-written observer for one reason — it tracks whatever `@Observable`
    /// state `label` happens to read, so the badge follows the playhead, the
    /// connection status *and* the preference that governs it without any of
    /// the three being named here.
    ///
    /// Deliberately not driven from the cue display's view tree, which is the
    /// obvious alternative and a trap: the main window can be closed while the
    /// session stays open, and a badge that stopped updating then would sit on
    /// the Dock naming a cue that is no longer standing by.
    func follow(_ label: @escaping @Sendable @MainActor () -> String?) {
        guard task == nil else { return }
        task = Task { @MainActor in
            // The last value actually applied, so that a change anywhere else
            // in the observed state does not repaint the Dock with a badge it
            // is already showing. `Observations` reports the transaction, not
            // whether this particular string moved — and behind `label` sits
            // the whole cue graph of a show that may have thousands of cues in
            // it, republished on every `/cueLists` refresh.
            //
            // Doubly optional on purpose: the outer `nil` is "nothing applied
            // yet", which is distinct from having applied "no badge", so the
            // first pass through always reaches the Dock.
            var applied: String??
            for await value in Observations(label) {
                guard applied != value else { continue }
                applied = value
                // No truncation of our own. A cue number too long for the
                // badge is AppKit's to shorten, and it already does — the
                // same way it shortens every other app's.
                NSApp.dockTile.badgeLabel = value
            }
        }
    }

    /// Stops following, and clears the badge.
    ///
    /// Nothing in the running app calls this — the badge lives as long as
    /// Cuety does. It exists so that "the badge is ours until we give it back"
    /// is stated rather than assumed, and so a test can leave the Dock as it
    /// found it.
    func stop() {
        task?.cancel()
        task = nil
        NSApp.dockTile.badgeLabel = nil
    }
}
