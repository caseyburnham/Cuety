import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

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
#if os(iOS)
        .compactToolbarActions(
            showsFloatingDisplay: horizontalSizeClass == .regular,
            showsDisconnect: true
        )
#else
        .onExitCommand {
            if model.isPresenting { model.togglePresentationMode() }
        }
#endif
    }

    private var detail: some View {
        GeometryReader { proxy in
            CueDisplayView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !model.isPresenting {
                        CueDrawerView(
                            availableHeight: proxy.size.height,
                            onClose: { model.resizeDrawer(toStep: 0) }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
        .frame(width: 1000, height: 620)
}
