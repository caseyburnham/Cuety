import AppKit

/// Keeps the pointer out of the way while the cue display is on stage.
///
/// `NSCursor.setHiddenUntilMouseMoves(true)` is the system call for hiding a
/// pointer, and it is exactly one shot: the pointer returns on the next
/// movement and then stays. At a desk that is correct. On an unattended stage
/// display it means one knock of the table leaves an arrow parked over the cue
/// number for the rest of the show.
///
/// So the request is re-armed. Every movement restarts a short idle delay, and
/// the pointer is hidden again when that expires — the behaviour of a
/// full-screen video player, for the same reason.
///
/// `setHiddenUntilMouseMoves(_:)` rather than `NSCursor.hide()` deliberately:
/// hide and unhide must be balanced, and a scheme that re-hides on a timer has
/// no way to promise that. This call sets a flag instead, so asking twice
/// costs nothing and no count can drift.
@MainActor
final class PointerHider {
    /// How long the pointer stays visible after being moved.
    ///
    /// Long enough to reach a menu or the green button without it vanishing
    /// mid-reach, short enough that a knocked table does not leave an arrow on
    /// the cue number.
    private static let idleDelay = Duration.seconds(3)

    /// The movement monitor, non-nil exactly while this is active.
    private var monitor: Any?

    /// The pending re-hide, cancelled and replaced on every movement.
    private var rearm: Task<Void, Never>?

    /// The window being watched, and the setting it had before.
    ///
    /// Weak because a window that has gone away needs nothing restored.
    private weak var window: NSWindow?
    private var windowAcceptedMouseMoved = false

    /// Hides the pointer, and keeps hiding it whenever movement stops.
    func begin(in window: NSWindow) {
        guard monitor == nil else { return }

        self.window = window
        // `.mouseMoved` is not dispatched to a window that has not asked for
        // it, so without this the monitor below would never fire once and the
        // pointer would never be hidden a second time.
        windowAcceptedMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        // Local, not global: a global monitor needs the accessibility
        // permission, and Cuety has no business asking an operator for that in
        // order to hide its own pointer. Movement inside its own window is the
        // only movement that reveals the pointer, so it is the only movement
        // worth knowing about.
        //
        // The drags are here because macOS posts those instead of `.mouseMoved`
        // while a button is held — scrolling the drawer would otherwise count
        // as stillness and hide the pointer under the operator's hand.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
        ) { [weak self] event in
            self?.scheduleHide()
            // Returned unchanged. This monitor observes; swallowing movement
            // would break every hover and drag in the window.
            return event
        }

        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// Stops hiding the pointer and puts it back.
    func end() {
        rearm?.cancel()
        rearm = nil

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        window?.acceptsMouseMovedEvents = windowAcceptedMouseMoved
        window = nil

        // Cancelling the request is the documented counterpart, and it is
        // needed rather than tidy: an operator who leaves presentation mode
        // from the keyboard has not moved the mouse, so nothing else would
        // bring the pointer back.
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    /// Re-hides the pointer once movement has stopped for ``idleDelay``.
    ///
    /// Replacing the task on every event means one is created per movement
    /// event while the mouse is actually moving. That is cheap, and the
    /// alternative — a deadline the timer polls — is more machinery for a
    /// hazard that lasts as long as someone's hand is on the mouse.
    private func scheduleHide() {
        rearm?.cancel()
        rearm = Task {
            try? await Task.sleep(for: Self.idleDelay)
            // `Task.sleep` returns early when cancelled, so this check is what
            // keeps a superseded re-hide from firing immediately — which would
            // hide the pointer while it was still being moved.
            guard !Task.isCancelled else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
