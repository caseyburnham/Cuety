import SwiftUI

/// The status and control items in the main window's toolbar.
///
/// These are real toolbar items rather than a floating cluster over the cue
/// display, so they inherit Liquid Glass, grouping, overflow, keyboard access,
/// and the standard titlebar metrics from the system instead of from hand-tuned
/// padding. The heartbeat sits in the `.status` position because it reports
/// state; the two controls group together at the trailing edge.
struct StatusToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HeartbeatIndicator()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            KeepAwakeToggle()
            ConnectionStatusButton()
        }
    }
}

/// Connection status, as a button that opens the inspector.
struct ConnectionStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var status: ConnectionStatus { model.client.status }

    var body: some View {
        Button {
            openWindow(id: WindowID.connectionInspector.rawValue)
        } label: {
            Label {
                Text("Connection Status")
            } icon: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tint)
                    // `.replace` animates between two different symbols; the
                    // variable-color effect conveys ongoing work while browsing
                    // or connecting, and stops once settled.
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: status.isTransitional)
            }
        }
        .animation(Motion.status, value: status)
        .help("\(status.title). \(status.detail)")
        .accessibilityLabel("Connection status: \(status.title)")
        .accessibilityValue(status.title)
        .accessibilityHint("Opens the connection status window")
    }
}

/// Beats once per received `/thump`.
///
/// The beat is driven off the heartbeat *count* rather than a timer, so it is a
/// true report of the link: when QLab stops answering, the glyph visibly stops
/// moving instead of continuing to animate reassuringly.
struct HeartbeatIndicator: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    /// Hidden entirely when there's no session to have a heartbeat.
    private var isRelevant: Bool { client.status.hasLiveData }

    var body: some View {
        if isRelevant {
            Image(systemName: "heart.fill")
                .foregroundStyle(tint)
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: client.heartbeatCount
                )
                .help(helpText)
                .accessibilityLabel("Heartbeat")
                .accessibilityValue(helpText)
        }
    }

    private var tint: Color {
        client.missedThumps > 0 ? .orange : .pink
    }

    private var helpText: String {
        guard client.heartbeatCount > 0 else {
            return "Waiting for the first heartbeat from QLab."
        }
        var text = "\(client.heartbeatCount) heartbeats"
        if let round = client.lastRoundTrip {
            text += ", last round trip \((round * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
        }
        if client.missedThumps > 0 {
            text += ". \(client.missedThumps) missed."
        }
        return text
    }
}

/// Toggles the keep-display-awake block.
struct KeepAwakeToggle: View {
    @Environment(AppModel.self) private var model

    private var isOn: Bool { model.preferences.keepsDisplayAwake }

    var body: some View {
        // Routed through the model rather than bound straight to the
        // preference: flipping this has to tell the sleep blocker as well, or
        // the setting and the actual assertion drift apart.
        Toggle(isOn: Binding(
            get: { isOn },
            set: { _ in model.toggleKeepAwake() }
        )) {
            Label(
                "Keep Display Awake",
                systemImage: isOn ? "sun.max.fill" : "moon.zzz.fill"
            )
            .foregroundStyle(isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
            .contentTransition(.symbolEffect(.replace))
        }
        .help(isOn
            ? "The display is being kept awake. Click to allow it to sleep."
            : "The display can sleep. Click to keep it awake.")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
