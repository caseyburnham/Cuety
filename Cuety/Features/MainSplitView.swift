import SwiftUI

struct MainSplitView<Sidebar: View, Detail: View>: View {
    let model: AppModel
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var compactColumn: NavigationSplitViewColumn

    init(
        model: AppModel,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.model = model
        self.sidebar = sidebar
        self.detail = detail
        _columnVisibility = State(
            initialValue: model.isSidebarVisible ? .all : .detailOnly
        )
        _compactColumn = State(
            initialValue: model.isSidebarVisible ? .sidebar : .detail
        )
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $compactColumn
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
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if model.isSidebarVisible != visible {
                model.setSidebarVisible(visible)
            }
        }
        .onChange(of: model.isSidebarVisible) { _, visible in
            let visibility: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            let column: NavigationSplitViewColumn = visible ? .sidebar : .detail
            withAnimation(Animation.default.unlessMotionIsReduced) {
                if columnVisibility != visibility {
                    columnVisibility = visibility
                }
                if compactColumn != column {
                    compactColumn = column
                }
            }
        }
    }
}
