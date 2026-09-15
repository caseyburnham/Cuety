import AppKit
import SwiftUI

/// The menu behind Cuety's menu bar item.
///
/// Its job is to be enough on its own. The reason to put a readout in the menu
/// bar at all is that the operator is working in QLab with Cuety's window
/// behind it or closed, so every action here has to be reachable without going
/// back to that window first — which is also why ``WorkspaceMenuItems`` is
/// shared with ``AppCommands`` rather than written out a second time.
///
/// No keyboard shortcuts, deliberately. The main menu bar already owns ⇧⌘F,
/// ⌘R and ⌘, and a second menu item claiming the same key equivalent is how
/// one of the two quietly stops working.
struct CueMenuBarContent: View {
    /// Passed rather than read from the environment, to match
    /// ``WorkspaceMenuItems`` — which ``AppCommands`` shares, and which cannot
    /// read the environment for the reason stated there.
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    private var client: QLabClient { model.client }

    var body: some View {
        Section {
            // Disabled: this is the readout, not an action. The same shape the
            // Connection menu uses to say "No Workspaces Found".
            Button(standbyDescription) {}
                .disabled(true)
        } header: {
            // The header follows the row. "Standing By" above the words "Not
            // Connected" would be a small lie of exactly the kind this app
            // spends its comments avoiding.
            Text(model.standbyCue == nil ? "Connection" : "Standing By")
        }

        Divider()

        Button("Show Cuety") { showMainWindow() }

        Toggle("Presentation Mode", isOn: Binding(
            get: { model.isPresenting },
            set: { _ in
                // Brought forward first. Presentation mode takes the main
                // window into real full screen, and asking a window that is
                // behind another app to do that leaves the operator looking at
                // whatever is still in front of it.
                showMainWindow()
                model.togglePresentationMode()
            }
        ))

        Divider()

        // Availability comes from ``AppModel`` rather than being tested here,
        // for the same reason the Connection menu takes it from there: four
        // surfaces now offer these two actions, and they must not disagree
        // about whether either is possible.
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

        // SwiftUI's own way in, so the Settings scene is opened the way the
        // app menu opens it rather than by sending a selector at AppKit.
        SettingsLink()

        Button("Quit Cuety") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// The cue standing by, in one line, or why there isn't one.
    private var standbyDescription: String {
        guard let cue = model.standbyCue else { return client.status.title }

        return switch (cue.displayNumber, cue.displayName) {
        case (let number?, let name?): "\(number) — \(name)"
        case (let number?, nil): number
        case (nil, let name?): name
        // A cue with neither a number nor a name is legal in QLab, and the
        // display has its own placeholder for it.
        case (nil, nil): "Untitled Cue"
        }
    }

    /// Brings the cue display forward, reopening it if it has been closed.
    private func showMainWindow() {
        // Activation and opening are two different things, and both are
        // needed: Cuety may not be the frontmost app — that is the entire
        // point of a menu bar item — and `openWindow` on its own does not
        // change which app the operator is in.
        NSApp.activate()
        openWindow(id: WindowID.main.rawValue)
    }
}
