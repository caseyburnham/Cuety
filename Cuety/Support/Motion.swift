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
