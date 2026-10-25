import SwiftUI

struct MainSplitView<Sidebar: View, Detail: View>: View {
    let model: AppModel
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            model.isSidebarVisible ? .all : .detailOnly
        } set: { visibility in
            let visible = visibility != .detailOnly
            guard model.isSidebarVisible != visible else { return }
            setSidebarVisible(visible)
        }
    }

    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding {
            model.isSidebarVisible ? .sidebar : .detail
        } set: { column in
            let visible = column == .sidebar
            guard model.isSidebarVisible != visible else { return }
            setSidebarVisible(visible)
        }
    }

    private func setSidebarVisible(_ visible: Bool) {
#if os(macOS)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.isSidebarVisible = visible
        }
#else
        model.isSidebarVisible = visible
#endif
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: columnVisibility,
            preferredCompactColumn: compactColumn
        ) {
            sidebar()
                .navigationTitle("Workspaces")
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 280,
                    max: 360
                )
        } detail: {
            detail()
        }
        .navigationSplitViewStyle(.balanced)
    }
}
