import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

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
    }

    static let drawerHeightShare: CGFloat = 0.45

    private var detail: some View {
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
