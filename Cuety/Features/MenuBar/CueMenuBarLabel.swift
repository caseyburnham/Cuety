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
        case .heartbeat: HeartbeatIndicator()
        }
    }

    @ViewBuilder
    private var cueNumber: some View {
        if let number = model.standbyCue?.displayNumber {
            Text(number)
                .monospacedDigit()
                .motion(Motion.status, value: number)
        } else {
            statusGlyph
        }
    }

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
