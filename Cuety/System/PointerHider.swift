#if os(macOS)
import AppKit

/// Hides the pointer while presenting, bringing it back as soon as the mouse
/// moves, and restores the window's mouse-move setting when presentation ends.
@MainActor
final class PointerHider {
    private static let idleDelay = Duration.seconds(3)

    private var monitor: Any?

    private var rearm: Task<Void, Never>?

    private weak var window: NSWindow?
    private var windowAcceptedMouseMoved = false

    func begin(in window: NSWindow) {
        // Observe local mouse events without consuming them, and restore the window setting in end().
        guard monitor == nil else { return }

        self.window = window
        windowAcceptedMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
        ) { [weak self] event in
            self?.scheduleHide()
            return event
        }

        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func end() {
        rearm?.cancel()
        rearm = nil

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        window?.acceptsMouseMovedEvents = windowAcceptedMouseMoved
        window = nil

        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func scheduleHide() {
        rearm?.cancel()
        rearm = Task {
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
#endif
