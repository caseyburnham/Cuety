import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MainSplitView(model: model) {
            WorkspaceSidebar()
        } detail: {
            detail
        }
#if os(macOS)
        // AppKit can cycle hosting constraints during animated panel resizing.
        // Scope this to panel state so cue and drawer animations keep working.
        .transaction(value: model.isDossierVisible) { $0.disablesAnimations = true }
        .transaction(value: model.isSidebarVisible) { $0.disablesAnimations = true }
#endif
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

    private var dossierInspector: some View {
#if os(macOS)
        StandbyDossierView()
#else
        NavigationStack {
            StandbyDossierView()
                .navigationTitle("Standby Dossier")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.isDossierVisible = false }
                    }
                }
        }
#endif
    }

    private var detail: some View {
        MainDetailView()
            .inspector(isPresented: Bindable(model).isDossierVisible) {
                dossierInspector
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
            .statusToolbarActions()
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
