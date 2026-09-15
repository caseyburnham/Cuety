import AppKit
import SwiftUI

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
        guard sidebarItem.isCollapsed == visible else { return }
        lastReportedVisibility = visible
        toggleSidebar(nil)
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
