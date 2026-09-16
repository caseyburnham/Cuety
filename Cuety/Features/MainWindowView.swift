import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

#if os(iOS)
    @State private var isShowingSettings = false
    @State private var isShowingActivityLog = false
    @State private var isShowingConnectionInspector = false
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!model.canRefresh)

                Button {
                    isShowingConnectionInspector = true
                } label: {
                    Image(systemName: model.client.status.systemImage)
                }

                Button {
                    isShowingActivityLog = true
                } label: {
                    Image(systemName: "heart.fill")
                }

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .sheet(isPresented: $isShowingActivityLog) {
            ActivityLogView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
        .sheet(isPresented: $isShowingConnectionInspector) {
            ConnectionInspectorView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
        }
#else
        .onExitCommand {
            if model.isPresenting { model.togglePresentationMode() }
        }
#endif
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
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
        .frame(width: 1000, height: 620)
}
