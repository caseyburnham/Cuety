import SwiftUI

struct CueMenuBarLabel: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        readout
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var readout: some View {
        switch model.preferences.menuBarReadout {
        case .cueNumber: cueNumber
        case .connectionStatus: statusGlyph
        case .heartbeat: HeartbeatIndicator(allowsAnimation: false)
        }
    }

    @ViewBuilder
    private var cueNumber: some View {
        // MenuBarExtra renders into an NSStatusItem button, which cannot
        // visually interpolate SwiftUI text animations and would otherwise
        // redraw the status item across animation ticks on every cue change.
        if let number = model.standbyCue?.displayNumber {
            Text(number)
                .monospacedDigit()
        } else {
            statusGlyph
        }
    }

    private var statusGlyph: some View {
        Image(systemName: client.status.systemImage)
            .foregroundStyle(client.status.tint)
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
            "Cuety. Heartbeat status."
        }
    }
}
