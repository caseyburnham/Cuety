import SwiftUI
import Testing

@testable import Cuety

@Suite("Drawer height bound")
@MainActor
struct DrawerBoundTests {
    private func heightOfferedAWindow(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(
            width: 900, height: Self.windowHeight
        )
        return renderer.nsImage?.size.height ?? 0
    }

    private static let windowHeight: CGFloat = 560

    private func rows(_ count: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                Color.clear.frame(height: Self.rowHeight)
            }
        }
    }

    private static let rowHeight: CGFloat = 24
    private static let bound: CGFloat = 252

    @Test("A drawer smaller than its bound keeps its own height")
    func shortContentIsNotStretched() throws {
        let natural = Self.rowHeight * 3
        try #require(natural < Self.bound)

        let bounded = heightOfferedAWindow(rows(3).scrollingBound(to: Self.bound))
        #expect(bounded == natural)
    }

    @Test("A drawer larger than its bound is held to it")
    func tallContentIsClamped() throws {
        try #require(Self.rowHeight * 21 > Self.bound)

        let bounded = heightOfferedAWindow(rows(21).scrollingBound(to: Self.bound))
        #expect(bounded == Self.bound)
    }

    @Test("No bound means the view is left exactly as it was")
    func noBoundIsNoChange() {
        let unbounded = heightOfferedAWindow(rows(21).scrollingBound(to: nil))
        #expect(unbounded == Self.rowHeight * 21)
    }

    @Test("The window's share leaves the display more room than the drawer")
    func shareFavoursTheDisplay() {
        let detailHeight = Self.windowHeight
        let drawerBound = detailHeight * MainWindowView.drawerHeightShare

        #expect(drawerBound < detailHeight / 2)
        #expect(drawerBound > CueRowView.Role.largestRowFontSize * 6)
    }
}
