import SwiftUI

/// The main window: workspace sidebar, cue display, header glyphs, and drawer.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A real `NSSplitViewController`, not a `NavigationSplitView` — see
        // ``MainSplitViewController`` for what that buys and why nothing else
        // would. It also means there is no `.toolbar(removing: .sidebarToggle)`
        // here any more: that existed to stop SwiftUI contributing a sidebar
        // control of its own, and SwiftUI has no split view to contribute one
        // for now.
        MainSplitView(model: model) {
            WorkspaceSidebar()
        } detail: {
            detail
        }
        .ignoresSafeArea()
        .task {
            // Browsing starts with the window, not with the app, so a launch
            // straight into a background scene doesn't hold the network open.
            //
            // Called unconditionally on purpose. `start()` is idempotent, so
            // closing this window and reopening it from the Window menu — the
            // one way this can run twice now that the scene is a single
            // `Window` — does not restart discovery or re-run auto-connect.
            model.start()
        }
        .sheet(item: Bindable(model).passcodePrompt) { prompt in
            PasscodeSheet(prompt: prompt)
        }
        // Presented here rather than from the sidebar, which used to own it
        // because it had the button that opened it. ⌘K from the Connection
        // menu is the only way in now, and a sheet the whole window puts up
        // should not depend on the sidebar being in the tree to do it.
        .sheet(isPresented: Bindable(model).isAddingServer) {
            AddServerSheet()
        }
        // Presentation mode is real full screen, which is the window's state
        // and not the layout's — see ``FullScreenPresentation``. A background
        // because the view is zero-sized and must not be able to affect the
        // size of anything.
        .background(
            FullScreenPresentation(isPresenting: model.isPresenting) { isFullScreen in
                model.setPresenting(isFullScreen)
            }
        )
        // Also zero-sized, and here for the same reason: the window's toolbar
        // is the window's, and SwiftUI can only describe one.
        //
        // Which is why there is no `.toolbar` or `.windowToolbarFullScreenVisibility`
        // anywhere in this view. Both ask SwiftUI to configure a toolbar, and
        // SwiftUI configures a toolbar by installing one of its own — so having
        // either meant SwiftUI and ``StatusToolbarController`` each replacing
        // the other's, rebuilding every item in the process. That showed up as
        // all four buttons flashing whenever the sidebar moved, and as a
        // freshly installed toolbar re-measuring and deciding the sidebar
        // control belonged in the overflow menu.
        //
        // Presentation mode loses nothing by it: hiding the toolbar in full
        // screen and revealing it when the pointer reaches the top of the
        // display is what macOS does with a title bar by default, and it is
        // where `.onHover` was asking for that behaviour from.
        .background(StatusToolbar())
    }

    /// The largest share of the detail area the drawer may occupy.
    ///
    /// The cue number is what the operator reads from across a room, so it gets
    /// the majority of the window whatever the drawer is set to show. Ten rows
    /// above the playhead and ten below — both allowed by Settings — otherwise
    /// come to more than the whole height of the window Cuety opens at.
    ///
    /// Not private, so ``DrawerBoundTests`` can hold the share itself to
    /// account rather than only the mechanism that applies it.
    static let drawerHeightShare: CGFloat = 0.45

    private var detail: some View {
        // Measures the detail area so the drawer's bound is a share of the
        // window rather than a point value that stops being right the moment
        // the window is resized.
        GeometryReader { proxy in
            CueDisplayView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.preferences.showsDrawer && !model.isPresenting {
                        CueDrawerView(
                            maxHeight: proxy.size.height * Self.drawerHeightShare
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        // No `.navigationTitle`/`.navigationSubtitle`. Those were what put a
        // leading titlebar accessory on the window, and an accessory holding
        // the leading region is what squeezed the toolbar into a trailing strip
        // the width of its own items — the toolbar's flexible space had nothing
        // left to expand into, so every control, the sidebar toggle included,
        // sat bunched at the right. ``StatusToolbarController`` sets
        // `NSWindow.title` and `.subtitle` directly instead, which is the same
        // two strings in the same place without the accessory.
        //
        // Escape leaves presentation mode. Still needed with real full screen:
        // macOS does not exit full screen on Escape, so without this the only
        // ways out are the menu bar and the green button — both of which have
        // to be revealed first, which is a bad place to be mid-show.
        .onExitCommand {
            if model.isPresenting { model.togglePresentationMode() }
        }
    }

}

#Preview {
    MainWindowView()
        .environment(AppModel())
        .frame(width: 1000, height: 620)
}
