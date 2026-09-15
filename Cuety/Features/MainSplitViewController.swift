import AppKit
import SwiftUI

/// The main window's sidebar-and-detail structure, as a real
/// `NSSplitViewController`.
///
/// AppKit for the structure, SwiftUI for the contents. This replaced a
/// `NavigationSplitView`, and the reason is the titlebar rather than the split
/// itself: `.sidebarTrackingSeparator` aligns itself with a titlebar *section*,
/// and a window only has one of those when its `contentViewController` is an
/// `NSSplitViewController` with a `behavior == .sidebar` item. SwiftUI's split
/// view is not that — it is a bare `NSSplitView` inside a hosting controller —
/// so the separator never drew, and the toolbar was handed a trailing region
/// the width of its own items. Every control ended up bunched at the right,
/// including the sidebar toggle, which belongs over the sidebar it toggles.
///
/// What comes with the real thing, none of which Cuety now implements: the
/// source-list material and its full-height vibrancy, the divider the
/// separator tracks, sidebar width autosaving, and the standard collapse
/// animation. `toggleSidebar:` also arrives here on its own, down the
/// responder chain from the system's toolbar item, so nothing has to route it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    /// Reported when the sidebar is collapsed or revealed by any route — the
    /// toolbar item, the View menu, or a drag of the divider — so ``AppModel``
    /// mirrors the window rather than only commanding it.
    var onSidebarVisibilityChange: (Bool) -> Void = { _ in }

    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem

    /// The last value handed to ``onSidebarVisibilityChange``, so only genuine
    /// changes are reported.
    ///
    /// `splitViewDidResizeSubviews` fires on every frame of a collapse and on
    /// every frame of a divider drag. Reporting each one wrote the same value
    /// to ``AppModel/isSidebarVisible`` dozens of times a second, and
    /// Observation does not deduplicate: each write invalidated the window's
    /// view, which re-entered this controller mid-animation through
    /// `updateNSViewController`. That is what made collapsing the sidebar
    /// stutter.
    private var lastReportedVisibility = true

    init(sidebar: NSViewController, detail: NSViewController) {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        detailItem = NSSplitViewItem(viewController: detail)
        super.init(nibName: nil, bundle: nil)

        // The bounds the sidebar was given as a `NavigationSplitView` column.
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        // The window holds still and the detail pane takes the space, which is
        // what Mail and Maps do. The default for a sidebar prefers resizing
        // the *window* instead, so collapsing during a show would have moved
        // the cue display rather than grown it.
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Full height, so the sidebar runs up behind the titlebar the way a
        // source list does everywhere else in macOS.
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .automatic

        // The detail pane is what a resize should grow, so it gets the lower
        // holding priority of the two.
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
        // Remembers the divider across launches, which is a thing the system
        // does for a split view and Cuety would otherwise have to persist.
        splitView.autosaveName = "com.ivxx.Cuety.mainSplitView"
    }

    // MARK: Sidebar visibility

    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }

    /// Collapses or reveals the sidebar, animated by AppKit.
    ///
    /// Through `toggleSidebar(_:)` rather than by setting
    /// `animator().isCollapsed`. Both animate, but only the action is the one
    /// the titlebar is coordinated with: it is what the system's own toolbar
    /// item sends and what Finder and Mail run, so the sidebar, the divider,
    /// the tracking separator and the items over the sidebar all move together
    /// as one transition. Setting the property drove the panes directly and
    /// left the titlebar to catch up, which read as the toggle jumping.
    ///
    /// Recording the value before toggling is what stops the echo: the
    /// notifications this produces are then already accounted for, so a
    /// collapse Cuety asked for is never reported back as one the operator
    /// performed — which would overwrite the visibility presentation mode
    /// saved in order to restore it.
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

    /// Enables the system's `toggleSidebar:` so the toolbar item and the View
    /// menu's Show/Hide Sidebar are both live.
    ///
    /// `NSSplitViewController` implements the action already; this only has to
    /// stop AppKit disabling the control, which it does for any responder that
    /// does not claim the selector.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSSplitViewController.toggleSidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

/// Puts ``MainSplitViewController`` in a SwiftUI scene, with SwiftUI on both
/// sides of the divider.
///
/// The sidebar and the detail are hosted once, in `makeNSViewController`, and
/// never rebuilt: they read ``AppModel`` from the environment themselves, so
/// there is nothing for an update to hand them. Re-hosting on every update
/// would throw away the list's selection and scroll position about once a
/// second, which is how often a heartbeat arrives.
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
        // The one thing that does flow down: the model's idea of whether the
        // sidebar is showing, which presentation mode sets.
        controller.setSidebarVisible(model.isSidebarVisible)
    }
}
