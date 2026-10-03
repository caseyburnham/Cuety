import SwiftUI

#if os(iOS)
private struct SidebarToolbarActions: ViewModifier {
    @Environment(AppModel.self) private var model

    @State private var isShowingStats = false
    @State private var isShowingEventHistory = false
    @State private var isShowingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Refresh Connections", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canRefresh || model.isRefreshing)

                    Menu {
                        Button("Stats", systemImage: "chart.bar") {
                            isShowingStats = true
                        }
                        Button("Event History", systemImage: "clock.arrow.circlepath") {
                            isShowingEventHistory = true
                        }
                        Button("Settings", systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $isShowingStats) {
                CuetyHostedContent(model: model) {
                    NavigationStack {
                        StatsView()
                            .navigationTitle("Stats")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isShowingStats = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $isShowingEventHistory) {
                CuetyHostedContent(model: model) {
                    NavigationStack {
                        EventHistoryView()
                            .navigationTitle("Event History")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isShowingEventHistory = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                CuetyHostedContent(model: model) { SettingsView() }
            }
    }
}

extension View {
    func sidebarToolbarActions() -> some View {
        modifier(SidebarToolbarActions())
    }
}
#endif
