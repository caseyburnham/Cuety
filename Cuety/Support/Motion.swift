import SwiftUI
#if os(macOS)
import AppKit
#endif

enum Motion {
    static let cueChange = Animation.spring(response: 0.34, dampingFraction: 0.82)

    static let pill = Animation.spring(response: 0.42, dampingFraction: 0.78)

    static let chrome = Animation.spring(response: 0.5, dampingFraction: 0.86)

    static let status = Animation.smooth(duration: 0.45)

    static let drawerShift = Animation.spring(response: 0.38, dampingFraction: 0.85)
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
        self
#endif
    }
}
