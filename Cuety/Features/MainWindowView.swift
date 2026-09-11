import SwiftUI

/// The main window: workspace sidebar, cue display, header glyphs, and drawer.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView(columnVisibility: Bindable(model).sidebarVisibility) {
            WorkspaceSidebar()
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
    }

    private var detail: some View {
        CueDisplayView()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.preferences.showsDrawer && !model.isPresenting {
                    CueDrawerView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar { StatusToolbarContent() }
            .toolbar(model.isPresenting ? .hidden : .automatic)
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            // Escape leaves presentation mode. Without this the only way out
            // is the menu, which is a bad place to be with the chrome hidden.
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
