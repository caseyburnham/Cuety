#if os(macOS)
import SwiftUI

struct StatusToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh Connections", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canRefresh || model.isRefreshing)
            .help(model.isRefreshing ? "Searching for QLab workspaces…" : "Refresh Connections")
        }

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
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .accessibilityLabel("Performance Mode")
            .tint(model.preferences.performanceMode ? .blue : .primary)
            .help(
                model.preferences.performanceMode
                    ? "Performance Mode On"
                    : "Performance Mode Off"
            )
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                openWindow(id: WindowID.connectionInspector.rawValue)
            } label: {
                Image(systemName: model.client.status.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.client.status.tint)
                    .accessibilityLabel("Connection Status")
            }
            .help("\(model.client.status.title) \(model.client.status.detail)")

            Button {
                openWindow(id: WindowID.activityLog.rawValue)
            } label: {
                Image(systemName: model.client.heartbeatSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.client.heartbeatTint)
                    .accessibilityLabel("Activity Log")
            }
            .help("Activity Log \(model.client.heartbeatSummary)")
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle("Standby Dossier", systemImage: "sidebar.right", isOn: Bindable(model).isDossierVisible)
                .help("Standby Dossier")
        }
    }
}
#endif
