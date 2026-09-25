import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MainSplitView(model: model) {
            WorkspaceSidebar()
        } detail: {
            detail
        }
        .ignoresSafeArea()
        .task {
            model.start()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.updateScenePhase(phase)
        }
        .sheet(item: Bindable(model).passcodePrompt) { prompt in
            PasscodeSheet(prompt: prompt)
        }
        .sheet(isPresented: Bindable(model).isAddingServer) {
            AddServerSheet()
        }
        .background(
            FullScreenPresentation(isPresenting: model.isPresenting) { isFullScreen in
                model.setPresenting(isFullScreen)
            }
        )
        .background(StatusToolbar())
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
#if os(macOS)
        .onExitCommand {
            if model.isPresenting { model.togglePresentationMode() }
        }
#endif
    }

    private var detail: some View {
        Group {
            switch model.preferences.cueLayout {
            case .display:
                GeometryReader { proxy in
                    CueDisplayView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if !model.isPresenting {
                                CueDrawerView(
                                    availableHeight: proxy.size.height
                                )
                                .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                }
            case .list:
                CueListView()
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
#if os(iOS)
        // Each split view column owns its own navigation bar, so the status
        // and heartbeat controls must be attached to the detail column to
        // stay visible on the cue display during a show.
        .compactToolbarActions(showsFloatingDisplay: false)
#endif
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
        .frame(width: 1000, height: 620)
}
