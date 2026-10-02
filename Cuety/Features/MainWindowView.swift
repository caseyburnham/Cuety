import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MainSplitView(model: model) {
            WorkspaceSidebar()
        } detail: {
            detail
        }
        .task {
            model.start()
        }
        .sheet(item: Bindable(model).passcodePrompt) { prompt in
            PasscodeSheet(prompt: prompt)
        }
        .sheet(isPresented: Bindable(model).isAddingServer) {
            AddServerSheet()
        }
        .credentialErrorAlert(Bindable(model).credentialError, isActive: model.passcodePrompt == nil)
#if os(macOS)
        .windowFullScreenBehavior(.enabled)
        .windowToolbarFullScreenVisibility(.visible)
        .toolbarVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar {
            StatusToolbar()
        }
#endif
    }

    private var detail: some View {
        MainDetailView()
#if os(iOS)
            // Each split view column owns its own navigation bar, so the status
            // and heartbeat controls must be attached to the detail column to
            // stay visible on the cue display during a show.
            .compactToolbarActions(
                showsRefresh: false,
                showsSettings: true,
                showsFloatingDisplay: false
            )
#endif
    }
}

/// The detail column's content. Keeping the layout switch in its own body
/// lets the native split view observe layout changes without rebuilding its
/// container.
private struct MainDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.preferences.cueLayout {
            case .display:
                GeometryReader { proxy in
                    CueDisplayView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            CueDrawerView(
                                availableHeight: proxy.size.height
                            )
                            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                        }
                }
                .ignoresSafeArea(.container, edges: .top)
            case .list:
                CueListView()
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel.preview)
        .frame(width: 1000, height: 620)
}
