import SwiftUI

private struct StatusToolbarActions: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var isShowingConnectionStatus = false
    @State private var isShowingActivityLog = false
#endif

    func body(content: Content) -> some View {
        content
            .toolbar {
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

                ToolbarItem(placement: .primaryAction) {
                    Button(
                        "Keep Display Awake",
                        systemImage: model.preferences.keepsDisplayAwake ? "sun.max.fill" : "sun.min"
                    ) {
                        model.setKeepsDisplayAwake(!model.preferences.keepsDisplayAwake)
                    }
                    .accessibilityValue(model.preferences.keepsDisplayAwake ? "On" : "Off")
                    .labelStyle(.iconOnly)
                    .tint(model.preferences.keepsDisplayAwake ? .orange : nil)
                    .help(model.preferences.keepsDisplayAwake ? "Keeping Display Awake" : "Allowing Display Sleep")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button(
                        "Performance Mode",
                        systemImage: model.preferences.performanceMode
                            ? "gauge.with.dots.needle.100percent"
                            : "gauge.with.dots.needle.33percent"
                    ) {
                        model.preferences.performanceMode.toggle()
                    }
                    .accessibilityValue(model.preferences.performanceMode ? "On" : "Off")
                    .labelStyle(.iconOnly)
                    .tint(model.preferences.performanceMode ? .blue : nil)
                    .help(model.preferences.performanceMode ? "Performance Mode On" : "Performance Mode Off")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: showConnectionStatus) {
                        Label {
                            Text("Connection Status")
                        } icon: {
                            Image(systemName: connectionStatusImage)
                                .foregroundStyle(connectionStatusTint)
                                .contentTransition(
                                    reduceMotion
                                        ? .identity
                                        : .symbolEffect(.replace.magic(fallback: .downUp))
                                )
                                .motion(Motion.status, value: connectionStatusImage)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(model.isDataStale ? "Data may be stale" : model.client.status.title)
                    .help(model.isDataStale
                          ? "Confirming the current cue with QLab."
                          : "\(model.client.status.title) \(model.client.status.detail)")

                    Button(action: showActivityLog) {
                        Label {
                            Text("Heartbeat and Activity Log")
                        } icon: {
                            HeartbeatIndicator()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(model.client.heartbeatSummary)
                    .help("Activity Log \(model.client.heartbeatSummary)")
                }
            }
#if os(iOS)
            .sheet(isPresented: $isShowingConnectionStatus) {
                CuetyHostedContent(model: model) {
                    NavigationStack {
                        ConnectionInspectorView()
                            .navigationTitle("Connection Status")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isShowingConnectionStatus = false }
                                }
                            }
                    }
                }
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

    private var connectionStatusImage: String {
        model.isDataStale ? "clock.badge.exclamationmark" : model.client.status.systemImage
    }

    private var connectionStatusTint: Color {
        model.isDataStale ? .orange : model.client.status.tint
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
