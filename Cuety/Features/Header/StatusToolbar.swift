import AppKit
import SwiftUI

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
            status: client.status,
            isRefreshing: model.isRefreshing,
            canRefresh: model.canRefresh,
            windowTitle: windowTitle,
            windowSubtitle: windowSubtitle
        )
    }

    private var windowTitle: String {
        model.client.workspace?.displayName ?? "Cuety"
    }

    private var windowSubtitle: String {
        let client = model.client
        guard client.status.hasLiveData else { return client.status.title }
        guard let listID = client.watchedCueListID,
              let list = client.cueLists.first(where: { $0.uniqueID == listID }),
              let name = list.displayName
        else { return client.status.title }
        return name
    }

    private var actions: StatusToolbarActions {
        StatusToolbarActions(
            toggleKeepAwake: { model.toggleKeepAwake() },
            openActivityLog: { openWindow(id: WindowID.activityLog.rawValue) },
            openConnectionInspector: { openWindow(id: WindowID.connectionInspector.rawValue) },
            refresh: { Task { await model.refresh() } }
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

        controller.scheduleUpdate(for: view, readout: readout)
    }
}
