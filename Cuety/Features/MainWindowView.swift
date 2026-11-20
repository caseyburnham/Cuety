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
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
#if os(macOS)
        GeometryReader { proxy in
            content
                .overlay(alignment: .top) {
                    // This stationary canvas has no scroll view to supply the
                    // toolbar's in-window blur. Sample the actual cue content.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: proxy.safeAreaInsets.top)
                        .offset(y: -proxy.safeAreaInsets.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
#else
        content
#endif
    }

    private var content: some View {
        Group {
            switch model.preferences.cueLayout {
            case .display:
                GeometryReader { proxy in
                    let drawerHeight = CueDrawerView.viewportHeight(
                        availableHeight: proxy.size.height,
                        step: model.drawerStep
                    )

                    ZStack(alignment: .bottom) {
                        CueDisplayView()
                            .padding(.bottom, drawerHeight)

                        CueDrawerView(
                            availableHeight: proxy.size.height
                        )
                        .transition(
                            reduceMotion
                                ? .identity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
