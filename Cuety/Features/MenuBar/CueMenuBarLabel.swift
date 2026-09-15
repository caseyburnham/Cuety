import SwiftUI

/// Cuety's menu bar item, as it appears while its menu is closed.
///
/// One of three readouts, chosen in Settings — see ``MenuBarReadout``. All
/// three are deliberately the *same* indicators the window shows rather than
/// menu-bar-sized reimplementations of them: the status glyph is
/// ``ConnectionStatus``'s own, and the heartbeat is the header bar's
/// ``HeartbeatIndicator``. A second opinion about whether Cuety is connected,
/// living up in the menu bar where it is read at a glance and never
/// questioned, is exactly the kind of disagreement this app has already had to
/// go and fix once.
struct CueMenuBarLabel: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        readout
            // The item's whole purpose stated once, since a glyph in the menu
            // bar has no label beside it to borrow meaning from.
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var readout: some View {
        switch model.preferences.menuBarReadout {
        case .cueNumber: cueNumber
        case .connectionStatus: statusGlyph
        case .heartbeat: HeartbeatIndicator()
        }
    }

    /// The cue standing by, or the status glyph when there is none.
    ///
    /// The fallback carries more weight than it looks. A menu bar item that
    /// drew nothing would be a zero-width thing the operator cannot click, and
    /// one that drew a placeholder dash would say only "no cue" — while the
    /// status glyph says *why* there is no cue, which is the next question
    /// anyone asks.
    @ViewBuilder
    private var cueNumber: some View {
        if let number = model.standbyCue?.displayNumber {
            // The menu bar's own font, left as the system set it: this item
            // sits in a row with every other app's, and is not the place to
            // have opinions about type.
            Text(number)
                // Tabular figures, so an advancing playhead does not shunt
                // every item to the left of this one sideways a pixel at a
                // time as the number changes shape.
                .monospacedDigit()
                .motion(Motion.status, value: number)
        } else {
            statusGlyph
        }
    }

    /// The status glyph the header bar shows, at menu bar size.
    ///
    /// Tinted, though the menu bar may render it as a template image and throw
    /// the colour away. Which is why the tint is not carrying the meaning on
    /// its own: every ``ConnectionStatus`` has a distinct glyph, so the readout
    /// survives being monochrome.
    private var statusGlyph: some View {
        Image(systemName: client.status.systemImage)
            .foregroundStyle(client.status.tint)
            .motion(Motion.status, value: client.status)
    }

    private var accessibilityLabel: String {
        switch model.preferences.menuBarReadout {
        case .cueNumber:
            if let number = model.standbyCue?.displayNumber {
                "Cuety. Standing by: cue \(number)."
            } else {
                "Cuety. \(client.status.title)."
            }
        case .connectionStatus:
            "Cuety. \(client.status.title)."
        case .heartbeat:
            "Cuety. \(client.heartbeatSummary)"
        }
    }
}
