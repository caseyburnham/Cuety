import SwiftUI

/// The main window: workspace sidebar, cue display, header glyphs, and drawer.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView(columnVisibility: Bindable(model).sidebarVisibility) {
            WorkspaceSidebar()
                // The toolbar is an `NSToolbar` now — see ``StatusToolbar``.
                // SwiftUI's automatic sidebar toggle would put a second,
                // SwiftUI-owned toolbar on the window and the two would take
                // turns evicting each other; ``StatusToolbarController``
                // contributes the sidebar control instead.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
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
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // Escape leaves presentation mode. Still needed with real full screen:
        // macOS does not exit full screen on Escape, so without this the only
        // ways out are the menu bar and the green button — both of which have
        // to be revealed first, which is a bad place to be mid-show.
        .onExitCommand {
            if model.isPresenting { model.togglePresentationMode() }
        }
    }

    private var navigationTitle: String {
        model.client.workspace?.displayName ?? "Cuety"
    }

    private var navigationSubtitle: String {
        guard model.client.status.hasLiveData else { return model.client.status.title }
        guard let listID = model.client.watchedCueListID,
              let list = model.client.cueLists.first(where: { $0.uniqueID == listID }),
              let name = list.displayName
        else { return model.client.status.title }
        return name
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
        .frame(width: 1000, height: 620)
}
