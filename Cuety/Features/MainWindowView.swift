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
#endif
    }

    private var detail: some View {
        MainDetailView()
            .statusToolbarActions()
#if os(macOS)
            // The status toolbar belongs to the detail column. Keep its native
            // translucent surface stable while either detail layout changes.
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
#endif
#if os(iOS)
            // The detail column owns this navigation bar. Keep its native
            // translucent surface stable while either detail layout changes.
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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
#if os(macOS)
                // The macOS window toolbar overlays the detail canvas. The
                // iPad navigation bar owns its safe area, so content should
                // be centered below it instead of behind it.
                .ignoresSafeArea(.container, edges: .top)
#endif
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
