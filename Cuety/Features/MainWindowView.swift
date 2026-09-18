import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isShowingSettings = false
    @State private var isShowingActivityLog = false
    @State private var isShowingConnectionInspector = false
    @State private var isShowingPresentationPIP = false
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
                        .foregroundStyle(model.client.status.tint)
                }
                .accessibilityLabel("Connection status")
                .accessibilityValue(model.client.status.title)

                Button {
                    isShowingActivityLog = true
                } label: {
                    Image(systemName: model.client.heartbeatSymbol)
                        .foregroundStyle(model.client.heartbeatTint)
                }
                .accessibilityLabel("Heartbeat and activity log")
                .accessibilityValue(model.client.heartbeatSummary)

                if horizontalSizeClass == .regular {
                    Button {
                        isShowingPresentationPIP = true
                    } label: {
                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                    }
                    .accessibilityLabel("Open presentation in a floating window")
                }

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }

                if model.canDisconnect {
                    Button(role: .destructive) {
                        model.disconnect()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityLabel("Disconnect")
                }
            }
        }
        .popover(isPresented: $isShowingPresentationPIP) {
            CueDisplayView()
                .environment(model)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
                .frame(minWidth: 360, idealWidth: 420, minHeight: 220, idealHeight: 260)
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
