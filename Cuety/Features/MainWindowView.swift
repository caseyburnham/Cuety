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
            model.start()
        }
        .sheet(item: Bindable(model).passcodePrompt) { prompt in
            PasscodeSheet(prompt: prompt)
        }
    }

    private var detail: some View {
        CueDisplayView()
            // The header floats over the display rather than pushing it down,
            // which is what lets the cue number use the full height.
            .overlay(alignment: .topTrailing) {
                if !model.isPresenting {
                    HeaderBar()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.preferences.showsDrawer && !model.isPresenting {
                    CueDrawerView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(backdrop)
            .toolbar(model.isPresenting ? .hidden : .automatic)
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            // Escape leaves presentation mode. Without this the only way out
            // is the menu, which is a bad place to be with the chrome hidden.
            .onExitCommand {
                if model.isPresenting { model.togglePresentationMode() }
            }
    }

    /// A very restrained gradient. The cue number is the subject; the
    /// background exists to give the Liquid Glass pills something to refract
    /// and to keep a large flat field from looking dead.
    private var backdrop: some View {
        Rectangle()
            .fill(.background)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.055),
                        Color.clear,
                        Color.accentColor.opacity(0.03),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
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
