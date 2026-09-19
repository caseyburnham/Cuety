import SwiftUI
import ShowControlCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Motion {
    static let cueChange = Animation.spring(response: ShowControlMotion.cueChangeResponse, dampingFraction: 0.82)

    static let pill = Animation.spring(response: 0.42, dampingFraction: 0.78)

    static let chrome = Animation.spring(response: ShowControlMotion.chromeResponse, dampingFraction: 0.86)

    static let status = Animation.smooth(duration: ShowControlMotion.statusDuration)

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
        UIAccessibility.isReduceMotionEnabled ? nil : self
#endif
    }
}
