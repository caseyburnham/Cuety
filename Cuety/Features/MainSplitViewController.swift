import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class MainSplitViewController: NSSplitViewController {
    var onSidebarVisibilityChange: (Bool) -> Void = { _ in }

    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem

    private var lastReportedVisibility = true

    init(sidebar: NSViewController, detail: NSViewController) {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        detailItem = NSSplitViewItem(viewController: detail)
        super.init(nibName: nil, bundle: nil)

        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .automatic

        detailItem.holdingPriority = .init(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController is built in code, never from a nib")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "com.ivxx.Cuety.mainSplitView"
    }

    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    func setSidebarVisible(_ visible: Bool) {
        guard isSidebarVisible != visible else { return }
        lastReportedVisibility = visible
        sidebarItem.isCollapsed = !visible
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        let visible = isSidebarVisible
        guard visible != lastReportedVisibility else { return }
        lastReportedVisibility = visible
        onSidebarVisibilityChange(visible)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSSplitViewController.toggleSidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

struct MainSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let model: AppModel
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeNSViewController(context: Context) -> MainSplitViewController {
        let controller = MainSplitViewController(
            sidebar: NSHostingController(rootView: sidebar().environment(model)),
            detail: NSHostingController(rootView: detail().environment(model))
        )
        controller.onSidebarVisibilityChange = { [model] visible in
            model.isSidebarVisible = visible
        }
        return controller
    }

    func updateNSViewController(_ controller: MainSplitViewController, context: Context) {
        controller.setSidebarVisible(model.isSidebarVisible)
    }
}
#else
struct MainSplitView<Sidebar: View, Detail: View>: View {
    let model: AppModel
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView(
            columnVisibility: $sidebarVisibility,
            preferredCompactColumn: $compactColumn
        ) {
            sidebar()
                .navigationTitle("Workspaces")
        } detail: {
            detail()
        }
        .onChange(of: model.isSidebarVisible) { _, visible in
            sidebarVisibility = visible ? .all : .detailOnly
            compactColumn = visible ? .sidebar : .detail
        }
        .onChange(of: sidebarVisibility) { _, visibility in
            model.isSidebarVisible = visibility != .detailOnly
        }
        .onChange(of: compactColumn) { _, column in
            model.isSidebarVisible = column == .sidebar
        }
    }

    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// Once the split view collapses into one column it ignores
    /// ``sidebarVisibility``, so the column on top is steered separately.
    /// Without this the sidebar is a dead end in a narrow window.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    init(
        model: AppModel,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.model = model
        self.sidebar = sidebar
        self.detail = detail
        _sidebarVisibility = State(initialValue: model.isSidebarVisible ? .all : .detailOnly)
        _compactColumn = State(initialValue: model.isSidebarVisible ? .sidebar : .detail)
    }
}
#endif
