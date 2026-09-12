import AppKit
import SwiftUI

/// The app's animation vocabulary.
///
/// Every animated transition in Cuety draws from this small set rather than
/// inventing its own timing. Consistent motion is most of what makes an
/// interface feel considered instead of assembled.
enum Motion {
    /// Cue number and name changes. Fast and slightly springy — a cue change
    /// should feel like a physical event, not a crossfade.
    static let cueChange = Animation.spring(response: 0.34, dampingFraction: 0.82)

    /// Detail pills appearing, disappearing, and morphing within their container.
    static let pill = Animation.spring(response: 0.42, dampingFraction: 0.78)

    /// Drawer opening and closing, and presentation-mode entry and exit.
    /// Slower, because it re-lays-out the whole window.
    static let chrome = Animation.spring(response: 0.5, dampingFraction: 0.86)

    /// Status glyph changes. Deliberately unhurried so a flapping connection
    /// doesn't produce a strobe in the corner of the operator's eye.
    static let status = Animation.smooth(duration: 0.45)

    /// Drawer row reflow when the playhead moves by one cue.
    static let drawerShift = Animation.spring(response: 0.38, dampingFraction: 0.85)
}

extension View {
    /// Animates changes to `value` with `animation`, unless the operator has
    /// asked for reduced motion.
    ///
    /// Use this in place of `.animation(_:value:)` everywhere Cuety animates.
    /// The check used to be written out at each call site, which meant eight
    /// of them silently did not have it: the sidebar honoured Reduce Motion
    /// and the display, drawer, pills and header did not. Making the guard
    /// part of the vocabulary rather than a thing to remember is the only
    /// version of this that stays true.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducibleMotion(animation: animation, value: value))
    }
}

/// Reads the accessibility setting from the environment, so the view updates
/// when it is switched during a session rather than only at launch.
private struct ReducibleMotion<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension Animation {
    /// This animation, or `nil` when the operator has asked for reduced
    /// motion — for the imperative `withAnimation` call sites, which have no
    /// environment to read.
    ///
    /// Views should prefer ``SwiftUICore/View/motion(_:value:)``: the
    /// environment is the canonical source and it invalidates the view when
    /// the setting changes, which reading `NSWorkspace` does not.
    @MainActor
    var unlessMotionIsReduced: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : self
    }
}
