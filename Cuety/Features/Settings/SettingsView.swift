import AppKit
import SwiftUI

/// Cuety's Settings window.
///
/// Four tabs, split by what the operator is thinking about rather than by which
/// type owns the value: how the app behaves, how the cue reads, what metadata
/// sits under it, and how Cuety talks to QLab.
///
/// A plain `TabView`, which in a `Settings` scene renders as the window's
/// toolbar — an icon above a label per pane, the standard macOS settings
/// selector. A segmented control in the title bar was tried instead and
/// reverted: it is reachable (a stock `Picker` in a `.principal` toolbar item,
/// the same construction as the Activity Log's filter) but it was not what was
/// wanted, and it costs the pane icons, which a segmented control cannot show.
/// No `tabViewStyle` turns the toolbar into a segmented control; `.grouped`
/// crushes the four labels into one pill and `.tabBarOnly` leaves the toolbar
/// as it is. All measured against the running app.
struct SettingsView: View {
    /// One width for every pane, so the window does not change shape sideways
    /// as the operator moves between panes — only its height changes, and only
    /// because the panes are genuinely different lengths.
    static let width: CGFloat = 540

    /// The panes, so the window can be sized for the one actually on screen.
    private enum Pane: Hashable, CaseIterable {
        case general, display, details, connection

        /// The height this pane needs to show everything without scrolling,
        /// taken from the pane itself rather than restated here.
        var height: CGFloat {
            switch self {
            case .general: GeneralSettingsView.settingsHeight
            case .display: DisplaySettingsView.settingsHeight
            case .details: DetailPillSettingsView.settingsHeight
            case .connection: ConnectionSettingsView.settingsHeight
            }
        }

        /// The shortest pane, which is the floor the window is held to.
        ///
        /// Derived rather than written down, so adding a pane or changing a
        /// pane's height cannot leave a stale number behind.
        static var shortest: CGFloat { allCases.map(\.height).min() ?? 0 }
    }

    @State private var pane: Pane = .general

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettingsView()
            }

            Tab("Display", systemImage: "textformat.size", value: Pane.display) {
                DisplaySettingsView()
            }

            Tab("Details", systemImage: "capsule.on.rectangle", value: Pane.details) {
                DetailPillSettingsView()
            }

            Tab("Connection", systemImage: "network", value: Pane.connection) {
                ConnectionSettingsView()
            }
        }
        // Width fixed, height flexible — and flexible is the point.
        //
        // A single 440pt window was well short of Display and Connection
        // and well over General: every pane but one either scrolled or sat
        // in empty space. So the window follows the pane, which is what
        // System Settings does when you move between panes of different
        // lengths.
        //
        // A `.frame(height:)` here cannot animate that smoothly. It makes
        // the window's height the *content's* height, so moving the window
        // means re-laying-out a whole `Form` and resizing the `NSWindow`
        // on every frame of the animation — which is exactly as janky as
        // it sounds. Leaving the height open lets each pane's `Form` fill
        // whatever it is given, so ``SettingsWindowHeight`` can hand the
        // frame to Core Animation and let the window server interpolate
        // it.
        //
        // The minimum is the shortest pane, so that if the resizer never
        // runs — no window, a future SDK declining the resize — Settings
        // opens at a sensible size and taller panes scroll, rather than
        // sprawling to no height at all. Dropping the constraint outright
        // did exactly that.
        .frame(
            minWidth: Self.width,
            maxWidth: Self.width,
            minHeight: Pane.shortest,
            maxHeight: .infinity
        )
        // Zero-sized and non-drawing; it is here for the window, not the
        // layout. A background rather than a sibling so it cannot affect
        // the size of anything.
        .background(
            SettingsWindowHeight(
                height: pane.height,
                isAnimated: !reduceMotion
            )
        )
    }
}

/// Sizes the Settings window to the pane on screen, animating the change.
///
/// AppKit, in an app that is otherwise entirely SwiftUI, because a window's
/// frame is genuinely AppKit's: there is no SwiftUI modifier that animates
/// one, and the nearest thing — animating the content's height and letting
/// the window follow — re-lays-out the whole pane on every frame.
///
/// `setFrame(_:display:animate:)` is the call macOS itself resizes windows
/// with, so this is the system's own behaviour rather than an imitation of it.
/// It is reached through `NSAnimationContext` instead of the `animate:` flag
/// because that flag blocks the main thread for the whole animation, and this
/// app holds a live OSC session whose heartbeat runs there.
private struct SettingsWindowHeight: NSViewRepresentable {
    /// The content height the window should settle at.
    let height: CGFloat

    let isAnimated: Bool

    /// Tracks whether this window has been sized once already.
    ///
    /// The first application must not animate: the Settings window is
    /// appearing at that moment, and a resize on top of the open animation
    /// reads as a wobble rather than as anything meaningful.
    final class Coordinator {
        var hasSized = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        let isAnimated = isAnimated
        let coordinator = context.coordinator

        // Deferred a turn of the run loop, for two reasons: `updateNSView`
        // runs inside SwiftUI's layout pass and resizing the window from
        // there re-enters it, and on the very first update the view has not
        // been added to a window yet, so there is nothing to resize.
        Task { @MainActor in
            guard let window = view.window else { return }
            Self.apply(
                height: height,
                paneHeight: view.frame.height,
                to: window,
                animated: isAnimated && coordinator.hasSized
            )
            coordinator.hasSized = true
        }
    }

    /// - Parameter paneHeight: The height the pane is *currently* getting,
    ///   measured from this view — which fills the pane exactly.
    @MainActor
    private static func apply(
        height: CGFloat, paneHeight: CGFloat, to window: NSWindow, animated: Bool
    ) {
        // The shortfall, measured, rather than derived from the window's
        // content rect.
        //
        // `contentRect(forFrameRect:)` looked like the right question and is
        // not: this window has a full-size content view, so it answers with
        // the whole frame, title bar included. Sizing against it therefore
        // handed every pane 88pt less than it asked for — the title bar's
        // worth — and the panes quietly scrolled. Worse, it read as already
        // correct, so the resize became a no-op and nothing moved at all.
        //
        // Asking the pane how tall it actually is needs no arithmetic about
        // title bars, and cannot drift if the chrome ever changes height.
        let delta = height - paneHeight
        // Sub-point differences are rounding, not a change of pane.
        guard abs(delta) > 0.5 else { return }

        var frame = window.frame
        frame.size.height += delta
        // A window is positioned from its bottom-left corner, so growing one
        // has to move its origin down by the same amount — otherwise it grows
        // downwards off the screen and away from the tab bar just clicked.
        frame.origin.y -= delta

        guard animated else {
            window.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            // The system's own duration for a resize of this magnitude,
            // rather than a number of ours: General to Connection is 500pt
            // and Display to Connection is 135pt, and they should not take
            // the same time.
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// Pinned to a height, because nothing drives ``SettingsWindowHeight`` outside
/// a real window and the flexible frame would otherwise sprawl.
///
/// Note that a preview host is not a `Settings` scene, so the tab selector it
/// draws is *not* the one the app shows: the preview gives a capsule of labels
/// and the real window gives the settings toolbar. Judge the selector and the
/// resize in the app, not here.
#Preview {
    SettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: GeneralSettingsView.settingsHeight)
}
