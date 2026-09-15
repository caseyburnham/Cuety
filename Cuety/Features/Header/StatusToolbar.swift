import AppKit
import SwiftUI

/// Installs the main window's toolbar and keeps it fed.
///
/// Zero-sized and non-drawing, like ``FullScreenPresentation``: it is here for
/// the window, not for the layout. Put it in a `background`, not in the
/// content.
///
/// A view of its own rather than a snapshot taken in ``MainWindowView``,
/// because reading the heartbeat is what schedules the next update: a body
/// that touches `heartbeatCount` re-evaluates every time one arrives. For
/// something zero-sized that costs nothing; for the split view it would cost
/// the whole window once a second.
struct StatusToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusToolbarHost(readout: readout, actions: actions)
    }

    private var readout: StatusToolbarReadout {
        let client = model.client
        return StatusToolbarReadout(
            keepsDisplayAwake: model.preferences.keepsDisplayAwake,
            heartbeatSymbol: client.heartbeatSymbol,
            heartbeatTint: client.heartbeatTint,
            heartbeatCount: client.heartbeatCount,
            heartbeatSummary: client.heartbeatSummary,
            status: client.status
        )
    }

    private var actions: StatusToolbarActions {
        StatusToolbarActions(
            // Routed through the model rather than at the preference directly:
            // flipping this has to tell the sleep blocker as well, or the
            // setting and the actual assertion drift apart.
            toggleKeepAwake: { model.toggleKeepAwake() },
            openActivityLog: { openWindow(id: WindowID.activityLog.rawValue) },
            openConnectionInspector: { openWindow(id: WindowID.connectionInspector.rawValue) }
        )
    }
}

private struct StatusToolbarHost: NSViewRepresentable {
    let readout: StatusToolbarReadout
    let actions: StatusToolbarActions

    func makeCoordinator() -> StatusToolbarController { StatusToolbarController() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let controller = context.coordinator
        let readout = readout
        controller.actions = actions

        // Deferred a turn of the run loop, for the two reasons
        // ``FullScreenPresentation`` defers: on the very first update the view
        // has not been added to a window yet, and reaching for the window
        // from inside SwiftUI's layout pass re-enters that pass.
        Task { @MainActor in
            guard let window = view.window else { return }
            controller.install(in: window)
            controller.apply(readout)
        }
    }
}
