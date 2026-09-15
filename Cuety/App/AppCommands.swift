import SwiftUI

/// Cuety's menu bar commands.
///
/// Everything reachable by mouse is also reachable from the menu bar with a
/// keyboard shortcut, which is both a HIG expectation and a practical one —
/// an operator mid-show should not have to hunt for a control.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // Cuety's own, because nothing contributes it any more. SwiftUI
            // added Show/Hide Sidebar for as long as the window was a
            // `NavigationSplitView`; it is an `NSSplitViewController` now —
            // see ``MainSplitViewController`` — and SwiftUI has no split view
            // to offer a command for. ⌃⌘S is the system's shortcut for it, so
            // the item that replaces it answers to the same keys.
            //
            // Written against ``AppModel/isSidebarVisible`` rather than by
            // sending `toggleSidebar:` down the responder chain: the model is
            // what presentation mode saves and restores, so routing the menu
            // around it would let the two disagree.
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button(model.isPresenting ? "Exit Presentation Mode" : "Enter Presentation Mode") {
                model.togglePresentationMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Toggle("Cue Drawer", isOn: Binding(
                get: { model.preferences.showsDrawer },
                set: { _ in model.toggleDrawer() }
            ))
            .keyboardShortcut("d", modifiers: [.command, .option])
        }

        // Connection actions get their own menu rather than being appended to
        // View: they act on the QLab session, not on what the window shows.
        // The Activity Log and Connection Status windows are deliberately absent
        // here — a `Window` scene already contributes its own Window-menu item,
        // and its `keyboardShortcut` binds to that item, so adding buttons for
        // them would produce a second copy of each command.
        CommandMenu("Connection") {
            // Named for what it does rather than the vaguer "Refresh": this
            // restarts discovery and rebuilds the session, which momentarily
            // interrupts the cue display. ⌘R is easy to hit by accident, so the
            // menu item should not undersell it.
            //
            // Availability comes from ``AppModel`` rather than being tested
            // here, so the menu and its keyboard shortcut cannot disagree with
            // the sidebar or the inspector about whether an action is possible.
            Button("Refresh Connections") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canRefresh)

            Button("Add Server…") {
                model.isAddingServer = true
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Disconnect") {
                model.disconnect()
            }
            .disabled(!model.canDisconnect)

            Divider()

            // Shared with the menu behind Cuety's menu bar item, which offers
            // the same choice for the same reason.
            WorkspaceMenuItems(model: model)
        }
    }
}
