import AppKit
import SwiftUI

/// Takes the main window into and out of real full screen for presentation
/// mode, and keeps ``AppModel/isPresenting`` honest about where the window
/// actually is.
///
/// AppKit, in an app that is otherwise entirely SwiftUI, for the same reason
/// ``SettingsWindowHeight`` is: full screen is a window's own state, and
/// SwiftUI can only *configure* it. `windowFullScreenBehavior(_:)` says
/// whether the green button is allowed to work; nothing in SwiftUI is the
/// green button. `toggleFullScreen(_:)` is the call macOS itself uses, so this
/// is the system's behaviour rather than an imitation of it.
///
/// Presentation mode used to be a layout change and nothing more — toolbar
/// hidden, sidebar collapsed, an ordinary window otherwise. On a stage machine
/// that left the menu bar, the Dock, the title bar and a mouse pointer sitting
/// over the cue number. Real full screen removes all four, and removes them the
/// way macOS does: the menu bar and Dock auto-hide and return on hover, which
/// is what the HIG asks for and what an operator reaching for QLab expects.
/// The pointer is ``PointerHider``'s job, and starts and stops with the
/// transition.
/// Deliberately *not* `NSApplication/presentationOptions` with `.hideDock` —
/// AppKit owns those flags for the duration of a full-screen transition, and
/// permanently disabling the Dock is the one thing the HIG names as a games-only
/// behaviour.
///
/// Zero-sized and non-drawing; it is here for the window, not the layout.
struct FullScreenPresentation: NSViewRepresentable {
    /// Whether Cuety wants to be presenting.
    let isPresenting: Bool

    /// Called when the *window* enters or leaves full screen, whoever asked.
    ///
    /// Full screen has more than one entrance: the green button, the system's
    /// own ⌃⌘F, Mission Control, dragging the window between spaces. Without
    /// this, any of them would leave ``AppModel/isPresenting`` describing a
    /// state the window is not in — the cue number at window scale on a
    /// full-screen display, and a View menu offering to enter a mode already
    /// entered.
    let onFullScreenChange: (Bool) -> Void

    /// Tracks the observed window and the transition in flight.
    final class Coordinator {
        /// Held for as long as the observation should last: the notification
        /// centre de-registers an observer when its token is released, so
        /// replacing this array is what stops observing the old window.
        private var observations: [NotificationCenter.ObservationToken] = []

        /// Weak, and compared by identity: closing the cue display and
        /// reopening it from the Window menu can hand this view a different
        /// `NSWindow`, and observing the old one would mean acting on a window
        /// nobody is looking at.
        private weak var observedWindow: NSWindow?

        /// True from `willEnter`/`willExit` until the matching `did`.
        private var isTransitioning = false

        /// Hides the pointer for as long as the window is presenting.
        private let pointer = PointerHider()

        /// Reassigned on every update, so the closure this calls is never a
        /// stale capture of an earlier `body`.
        var onFullScreenChange: (Bool) -> Void = { _ in }

        func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            observedWindow = window

            let center = NotificationCenter.default
            observations = [
                center.addObserver(
                    of: window, for: NSWindow.WillEnterFullScreenMessage.self
                ) { [weak self] _ in self?.isTransitioning = true },

                center.addObserver(
                    of: window, for: NSWindow.WillExitFullScreenMessage.self
                ) { [weak self] _ in self?.isTransitioning = true },

                center.addObserver(
                    of: window, for: NSWindow.DidEnterFullScreenMessage.self
                ) { [weak self] _ in self?.settle(isFullScreen: true) },

                center.addObserver(
                    of: window, for: NSWindow.DidExitFullScreenMessage.self
                ) { [weak self] _ in self?.settle(isFullScreen: false) },

                // A closing window is the one way out of presenting that has
                // no `didExitFullScreen` to rely on, and leaving the pointer's
                // event monitor installed on a window that no longer exists
                // would be a leak with nothing left to remove it.
                center.addObserver(
                    of: window, for: NSWindow.WillCloseMessage.self
                ) { [weak self] _ in self?.pointer.end() },
            ]
        }

        /// Matches the window to `presenting`, or does nothing if it already is.
        func apply(isPresenting presenting: Bool, to window: NSWindow) {
            // Compared against the window's own state rather than a remembered
            // copy of it. Someone who used the green button has already changed
            // it and ``settle(isFullScreen:)`` has already told the model — so
            // by the time this runs there is nothing to do, and toggling anyway
            // would undo exactly what they asked for.
            guard window.styleMask.contains(.fullScreen) != presenting else { return }
            // Toggling mid-transition is how AppKit ends up half in full
            // screen. ⇧⌘F pressed twice in a second is not hypothetical on a
            // show machine. The request is dropped rather than queued: the
            // `did` notification will reconcile the model with wherever the
            // window ends up, so nothing is left stuck.
            guard !isTransitioning else { return }
            window.toggleFullScreen(nil)
        }

        private func settle(isFullScreen: Bool) {
            isTransitioning = false
            // Started here rather than on the way in, because the full-screen
            // transition tracks the pointer: a pointer hidden before the
            // animation is back by the end of it.
            if isFullScreen, let observedWindow {
                pointer.begin(in: observedWindow)
            } else {
                pointer.end()
            }
            onFullScreenChange(isFullScreen)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isPresenting = isPresenting
        let coordinator = context.coordinator
        coordinator.onFullScreenChange = onFullScreenChange

        // Deferred a turn of the run loop, for the two reasons
        // ``SettingsWindowHeight`` defers: on the very first update the view has
        // not been added to a window yet, and taking the window into full
        // screen from inside SwiftUI's layout pass re-enters that pass.
        Task { @MainActor in
            guard let window = view.window else { return }
            coordinator.observe(window)
            coordinator.apply(isPresenting: isPresenting, to: window)
        }
    }
}
