import SwiftUI

struct MainSplitView<Sidebar: View, Detail: View>: View {
    let model: AppModel
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    @State private var sidebarVisibility: NavigationSplitViewVisibility
    @State private var compactColumn: NavigationSplitViewColumn

    init(
        model: AppModel,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.model = model
        self.sidebar = sidebar
        self.detail = detail
        _sidebarVisibility = State(
            initialValue: model.isSidebarVisible ? .all : .detailOnly
        )
        _compactColumn = State(
            initialValue: model.isSidebarVisible ? .sidebar : .detail
        )
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $sidebarVisibility,
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
        .onChange(of: model.isSidebarVisible) { _, visible in
            let visibility: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            let column: NavigationSplitViewColumn = visible ? .sidebar : .detail

#if os(macOS)
            // AppKit can cycle hosting constraints during animated panel
            // resizing. Keep this suppression local to the split-view state
            // update so detail content and its toolbar retain their motion.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if sidebarVisibility != visibility {
                    sidebarVisibility = visibility
                }
                if compactColumn != column {
                    compactColumn = column
                }
            }
#else
            if sidebarVisibility != visibility {
                sidebarVisibility = visibility
            }
            if compactColumn != column {
                compactColumn = column
            }
#endif
        }
        .onChange(of: sidebarVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if model.isSidebarVisible != visible {
                model.isSidebarVisible = visible
            }
        }
        .onChange(of: compactColumn) { _, column in
            let visible = column == .sidebar
            if model.isSidebarVisible != visible {
                model.isSidebarVisible = visible
            }
        }
    }
}
