import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Motion {
    /// Finite ease-out curve so cue changes settle in 200 ms instead of ticking
    /// a long spring tail across dozens of frames of giant display text.
    static let cueChange = Animation.easeOut(duration: 0.2)

    static let pill = Animation.spring(response: 0.42, dampingFraction: 0.78)

    static let chrome = Animation.spring(response: 0.50, dampingFraction: 0.86)

    /// Display typography follows the window's continuous resize rather than
    /// the spring used for discrete chrome changes.
    static let displayResize = Animation.smooth(duration: 0.28)

    static let status = Animation.smooth(duration: 0.45)

    static let drawerShift = Animation.spring(response: 0.38, dampingFraction: 0.85)

    /// The cue list layout moving every cue one position on a go. Smooth
    /// rather than springy, since the standby cue travels a long way.
    static let listShift = Animation.smooth(duration: 0.45)
}

extension View {
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducibleMotion(animation: animation, value: value))
    }
}

private struct ReducibleMotion<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension Animation {
    @MainActor
    var unlessMotionIsReduced: Animation? {
#if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : self
#else
        UIAccessibility.isReduceMotionEnabled ? nil : self
#endif
    }
}
