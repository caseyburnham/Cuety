import SwiftUI

#if os(iOS)
private struct SidebarToolbarActions: ViewModifier {
    @Environment(AppModel.self) private var model

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
                        Section("View") {
                            Toggle("Cue List Layout", isOn: Binding(
                                get: { model.preferences.cueLayout == .list },
                                set: { model.setCueLayout($0 ? .list : .display) }
                            ))

                            Toggle("Cue Drawer", isOn: Binding(
                                get: { model.preferences.showsDrawer },
                                set: { model.setShowsDrawer($0) }
                            ))
                            .disabled(model.preferences.cueLayout == .list)
                        }

                        Section("Connection") {
                            Button("Add Server…", systemImage: "plus") {
                                model.isAddingServer = true
                            }

                            Button("Disconnect") {
                                model.disconnect()
                            }
                            .disabled(!model.canDisconnect)
                        }

                        Section {
                            Button("Settings", systemImage: "gearshape") {
                                isShowingSettings = true
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                CuetyHostedContent(model: model) {
                    NavigationStack {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { isShowingSettings = false }
                                }
                            }
                    }
                }
            }
    }
}

extension View {
    func sidebarToolbarActions() -> some View {
        modifier(SidebarToolbarActions())
    }
}
#endif
