import SwiftUI
import Testing

@testable import Cuety

/// The drawer's height bound, measured.
///
/// `F14` found the drawer unbounded: at the ten-above/ten-below maximum that
/// Settings allows, in the 900×560 window Cuety opens at, it reduced the
/// headline cue number to a clipped sliver of glyph tops *and* still lost its
/// own furthest rows off the bottom edge with nothing to say so. The number is
/// the thing an operator reads from across a room, so the drawer is now capped
/// at a share of the window.
///
/// These tests measure real rendered heights rather than asserting that the
/// modifier chain is spelled a particular way. ``View/scrollingBound(to:)``
/// leans on `fixedSize` and `frame(maxHeight:)` composing to
/// `min(content, bound)`, and that is an easy thing to be wrong about in either
/// direction — a scroll view that ignores the bound and fills the window, or
/// one that takes the whole bound even when three rows would do.
@Suite("Drawer height bound")
@MainActor
struct DrawerBoundTests {
    /// The rendered height of a view, in points.
    private func height(of view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 900))
        return renderer.nsImage?.size.height ?? 0
    }

    /// A stack of plain rows, tall enough to be predictable without depending
    /// on the operator's chosen font family.
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
    func shortContentIsNotStretched() {
        let content = rows(3)
        let natural = height(of: content)
        try? #require(natural > 0)

        // A bare `ScrollView` would fill whatever it was offered here, leaving
        // the drawer 252pt tall to show three rows and taking that space from
        // the cue number for nothing.
        #expect(height(of: content.scrollingBound(to: Self.bound)) == natural)
        #expect(natural < Self.bound)
    }

    @Test("A drawer larger than its bound is held to it")
    func tallContentIsClamped() {
        // Twenty rows plus the playhead marker — the configured maximum.
        let content = rows(21)
        try? #require(height(of: content) > Self.bound)

        #expect(height(of: content.scrollingBound(to: Self.bound)) == Self.bound)
    }

    @Test("No bound means the view is left exactly as it was")
    func noBoundIsNoChange() {
        let content = rows(21)

        // The drawer is a `safeAreaInset`, which wants the inset view's natural
        // height. Wrapping it in a scroll view "just in case" would break that
        // even with a generous bound.
        #expect(height(of: content.scrollingBound(to: nil)) == height(of: content))
    }

    /// The bound has to leave the cue number the majority of the window,
    /// because the number is the reason the app is on the wall.
    @Test("The window's share leaves the display more room than the drawer")
    func shareFavoursTheDisplay() {
        let detailHeight: CGFloat = 560
        let drawerBound = detailHeight * MainWindowView.drawerHeightShare

        #expect(drawerBound < detailHeight / 2)
        // And enough room to be worth having: the focal row below the playhead
        // is 22pt, so a bound that could not fit several rows either side of
        // the marker would make the drawer useless rather than merely small.
        #expect(drawerBound > CueRowView.Role.largestRowFontSize * 6)
    }
}
