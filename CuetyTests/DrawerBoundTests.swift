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
    /// The height a view resolves to when offered a whole window, in points.
    ///
    /// The offer is the whole point. A scroll view given more room than its
    /// content needs will take it, and that is the fault under test — so these
    /// measurements set `proposedSize` explicitly rather than letting
    /// `ImageRenderer` propose `nil`, which is an offer of nothing in
    /// particular and lets an over-eager view look well behaved. A first
    /// attempt at these tests omitted it and passed with the fix removed.
    ///
    /// Reading the resolved size back off the image keeps this synchronous. A
    /// second attempt measured from inside with `onGeometryChange`, whose
    /// action does not run in step with the render: it passed alone and failed
    /// in the suite.
    private func heightOfferedAWindow(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(
            width: 900, height: Self.windowHeight
        )
        return renderer.nsImage?.size.height ?? 0
    }

    private static let windowHeight: CGFloat = 560

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
    func shortContentIsNotStretched() throws {
        let natural = Self.rowHeight * 3
        try #require(natural < Self.bound)

        // Three rows, offered a 560pt window. A scroll view that took the room
        // on offer would leave the drawer 252pt tall to show 72pt of cues, and
        // the cue number would have paid for the difference.
        let bounded = heightOfferedAWindow(rows(3).scrollingBound(to: Self.bound))
        #expect(bounded == natural)
    }

    @Test("A drawer larger than its bound is held to it")
    func tallContentIsClamped() throws {
        // Twenty rows plus the playhead marker — the configured maximum.
        try #require(Self.rowHeight * 21 > Self.bound)

        let bounded = heightOfferedAWindow(rows(21).scrollingBound(to: Self.bound))
        #expect(bounded == Self.bound)
    }

    @Test("No bound means the view is left exactly as it was")
    func noBoundIsNoChange() {
        // The drawer is a `safeAreaInset`, which wants the inset view's natural
        // height. Wrapping it in a scroll view "just in case" would break that
        // even with a generous bound.
        let unbounded = heightOfferedAWindow(rows(21).scrollingBound(to: nil))
        #expect(unbounded == Self.rowHeight * 21)
    }

    /// The bound has to leave the cue number the majority of the window,
    /// because the number is the reason the app is on the wall.
    @Test("The window's share leaves the display more room than the drawer")
    func shareFavoursTheDisplay() {
        let detailHeight = Self.windowHeight
        let drawerBound = detailHeight * MainWindowView.drawerHeightShare

        #expect(drawerBound < detailHeight / 2)
        // And enough room to be worth having: the focal row below the playhead
        // is 22pt, so a bound that could not fit several rows either side of
        // the marker would make the drawer useless rather than merely small.
        #expect(drawerBound > CueRowView.Role.largestRowFontSize * 6)
    }
}
