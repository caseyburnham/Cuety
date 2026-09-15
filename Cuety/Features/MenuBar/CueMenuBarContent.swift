import AppKit
import SwiftUI

struct CueMenuBarContent: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    private var client: QLabClient { model.client }

    var body: some View {
        Section {
            Button(standbyDescription) {}
                .disabled(true)
        } header: {
            Text(model.standbyCue == nil ? "Connection" : "Standing By")
        }

        Divider()

        Button("Show Cuety") { showMainWindow() }

        Toggle("Presentation Mode", isOn: Binding(
            get: { model.isPresenting },
            set: { _ in
                showMainWindow()
                model.togglePresentationMode()
            }
        ))

        Divider()

        Button("Refresh Connections") {
            Task { await model.refresh() }
        }
        .disabled(!model.canRefresh)

        Button("Disconnect") {
            model.disconnect()
        }
        .disabled(!model.canDisconnect)

        Divider()

        WorkspaceMenuItems(model: model)

        Divider()

        SettingsLink()

        Button("Quit Cuety") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var standbyDescription: String {
        guard let cue = model.standbyCue else { return client.status.title }

        return switch (cue.displayNumber, cue.displayName) {
        case (let number?, let name?): "\(number) — \(name)"
        case (let number?, nil): number
        case (nil, let name?): name
        case (nil, nil): "Untitled Cue"
        }
    }

    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: WindowID.main.rawValue)
    }
}
