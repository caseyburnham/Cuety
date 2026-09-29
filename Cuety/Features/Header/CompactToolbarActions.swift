import SwiftUI

#if os(iOS)
/// The trailing toolbar controls shared by the iOS surfaces, together with
/// the sheets and popover they present. The sidebar and the cue display show
/// the same set of actions, so they live here once and each surface only
/// chooses which of the optional items apply to it.
struct CompactToolbarActions: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var showsRefresh = true
    var showsConnectionStatus = true
    var showsHeartbeat = true
    var showsSettings = true

    /// Only useful where the cue display itself isn't already on screen.
    var showsFloatingDisplay = true

    @State private var isShowingSettings = false
    @State private var isShowingActivityLog = false
    @State private var isShowingConnectionInspector = false
    @State private var isShowingFloatingDisplay = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if showsRefresh {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!model.canRefresh)
                        .accessibilityLabel("Refresh")
                    }

                    if showsConnectionStatus {
                        Button {
                            isShowingConnectionInspector = true
                        } label: {
                            Image(systemName: model.isDataStale ? "clock.badge.exclamationmark" : model.client.status.systemImage)
                                .foregroundStyle(model.isDataStale ? AnyShapeStyle(.orange) : AnyShapeStyle(model.client.status.tint))
                        }
                        .accessibilityLabel(model.isDataStale ? "Data may be stale" : "Connection status")
                        .accessibilityValue(model.isDataStale ? "Return to the foreground to confirm the current cue" : model.client.status.title)
                    }

                    if showsHeartbeat {
                        Button {
                            isShowingActivityLog = true
                        } label: {
                            Image(systemName: model.client.heartbeatSymbol)
                                .foregroundStyle(model.client.heartbeatTint)
                                .contentTransition(
                                    reduceMotion
                                        ? .identity
                                        : .symbolEffect(.replace.magic(fallback: .downUp))
                                )
                                .symbolEffect(
                                    .bounce,
                                    options: .nonRepeating,
                                    value: reduceMotion ? 0 : model.client.heartbeatCount
                                )
                        }
                        .accessibilityLabel("Heartbeat and activity log")
                        .accessibilityValue(model.client.heartbeatSummary)
                    }

                    if showsFloatingDisplay {
                        Button {
                            isShowingFloatingDisplay = true
                        } label: {
                            Image(systemName: "rectangle.inset.filled.and.person.filled")
                        }
                        .accessibilityLabel("Open floating cue display")
                    }

                    if showsSettings {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .popover(isPresented: $isShowingFloatingDisplay) {
                presented {
                    CueDisplayView()
                        .frame(minWidth: 360, idealWidth: 420, minHeight: 220, idealHeight: 260)
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                presented { SettingsView() }
            }
            .sheet(isPresented: $isShowingActivityLog) {
                presented { ActivityLogView() }
            }
            .sheet(isPresented: $isShowingConnectionInspector) {
                presented { ConnectionInspectorView() }
            }
    }

    /// Presented content sits outside the presenting view's environment, so
    /// hand it back the model and the chosen appearance.
    private func presented(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .environment(model)
            .preferredColorScheme(model.preferences.appearance.colorScheme)
    }
}

extension View {
    func compactToolbarActions(
        showsRefresh: Bool = true,
        showsConnectionStatus: Bool = true,
        showsHeartbeat: Bool = true,
        showsSettings: Bool = true,
        showsFloatingDisplay: Bool = true
    ) -> some View {
        modifier(
            CompactToolbarActions(
                showsRefresh: showsRefresh,
                showsConnectionStatus: showsConnectionStatus,
                showsHeartbeat: showsHeartbeat,
                showsSettings: showsSettings,
                showsFloatingDisplay: showsFloatingDisplay
            )
        )
    }
}
#endif
