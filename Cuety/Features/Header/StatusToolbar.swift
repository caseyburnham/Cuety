import SwiftUI

struct StatusToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    let showConnectionStatus: () -> Void
    let showActivityLog: () -> Void

    var body: some ToolbarContent {
#if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh Connections", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canRefresh || model.isRefreshing)
            .help(model.isRefreshing ? "Searching for QLab workspaces…" : "Refresh Connections")
        }
#endif

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(
                isOn: Binding(
                    get: { model.preferences.keepsDisplayAwake },
                    set: { model.setKeepsDisplayAwake($0) }
                )
            ) {
                Image(
                    systemName: model.preferences.keepsDisplayAwake
                        ? "sun.max.fill"
                        : "sun.min"
                )
            }
            .toggleStyle(.button)
            .accessibilityLabel("Keep Display Awake")
            .tint(model.preferences.keepsDisplayAwake ? .orange : .primary)
            .help(
                model.preferences.keepsDisplayAwake
                    ? "Keeping Display Awake"
                    : "Allowing Display Sleep"
            )

            Toggle(
                isOn: Binding(
                    get: { model.preferences.performanceMode },
                    set: { model.preferences.performanceMode = $0 }
                )
            ) {
                Image(
                    systemName: model.preferences.performanceMode
                        ? "gauge.with.dots.needle.100percent"
                        : "gauge.with.dots.needle.33percent"
                )
            }
            .toggleStyle(.button)
            .accessibilityLabel("Performance Mode")
            .tint(model.preferences.performanceMode ? .blue : .primary)
            .help(
                model.preferences.performanceMode
                    ? "Performance Mode On"
                    : "Performance Mode Off"
            )

            Button(action: showConnectionStatus) {
                Image(systemName: model.isDataStale ? "clock.badge.exclamationmark" : model.client.status.systemImage)
                    .foregroundStyle(model.isDataStale ? .orange : model.client.status.tint)
            }
            .accessibilityLabel("Connection Status")
            .accessibilityValue(model.isDataStale ? "Data may be stale" : model.client.status.title)
            .help(
                model.isDataStale
                    ? "Confirming the current cue with QLab."
                    : "\(model.client.status.title) \(model.client.status.detail)"
            )

            Button(action: showActivityLog) {
                HeartbeatIndicator()
            }
            .accessibilityLabel("Heartbeat and Activity Log")
            .accessibilityValue(model.client.heartbeatSummary)
            .help("Activity Log \(model.client.heartbeatSummary)")

            Toggle("Standby Dossier", systemImage: "sidebar.right", isOn: Bindable(model).isDossierVisible)
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Standby Dossier")
        }
    }
}

private struct StatusToolbarActions: ViewModifier {
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @Environment(AppModel.self) private var model
    @State private var isShowingConnectionStatus = false
    @State private var isShowingActivityLog = false
#endif

    func body(content: Content) -> some View {
        content
            .toolbar {
                StatusToolbar(
                    showConnectionStatus: showConnectionStatus,
                    showActivityLog: showActivityLog
                )
            }
#if os(iOS)
            .sheet(isPresented: $isShowingConnectionStatus) {
                CuetyHostedContent(model: model) { ConnectionInspectorView() }
            }
            .sheet(isPresented: $isShowingActivityLog) {
                CuetyHostedContent(model: model) { ActivityLogView() }
            }
#endif
    }

    private func showConnectionStatus() {
#if os(macOS)
        openWindow(id: WindowID.connectionInspector.rawValue)
#else
        isShowingConnectionStatus = true
#endif
    }

    private func showActivityLog() {
#if os(macOS)
        openWindow(id: WindowID.activityLog.rawValue)
#else
        isShowingActivityLog = true
#endif
    }
}

extension View {
    func statusToolbarActions() -> some View {
        modifier(StatusToolbarActions())
    }
}
