import SwiftUI

/// The status and control items in the main window's toolbar.
///
/// These are real toolbar items rather than a floating cluster over the cue
/// display, so they inherit Liquid Glass, grouping, overflow, keyboard access,
/// and the standard titlebar metrics from the system instead of from hand-tuned
/// padding.
struct StatusToolbarContent: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            KeepAwakeToggle()
        }

        // Adjacent items share one Liquid Glass container by default, which
        // made the toggle look like a third status glyph. A fixed spacer is how
        // you tell the system these are two separate groupings.
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            ConnectionStatusIndicator()
        }
    }
}

/// The heartbeat and the connection glyph, paired, as one button onto the
/// connection inspector.
///
/// Two glyphs because they answer two questions that can disagree: *what state
/// is the session in* and *is traffic actually flowing right now*. A session
/// can read `connected` while the far end has gone quiet — the heart is what
/// shows that in the second before the missed-thump count catches up and turns
/// the status glyph amber.
///
/// One control rather than two loose images side by side: a bare `Image` in a
/// toolbar item gets none of the padding the system gives a button, so the
/// heart sat flush against the edge of its glass container. Wrapping both
/// glyphs in one button hands the metrics back to the system — and one hit
/// target is right anyway, since both glyphs report on the same link and the
/// inspector is where the detail behind them lives.
///
/// Both glyphs are always present, and each says what it has to say by changing
/// itself. Nothing appears or disappears, so the pair never changes width and
/// never shoves the rest of the toolbar sideways.
struct ConnectionStatusIndicator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var client: QLabClient { model.client }
    private var status: ConnectionStatus { client.status }

    /// Whether there's a session that could produce a heartbeat at all.
    private var isLive: Bool { status.hasLiveData }

    var body: some View {
        Button {
            openWindow(id: WindowID.connectionInspector.rawValue)
        } label: {
            // An explicit stack rather than a `Label`: the toolbar's icon-only
            // label style would collapse a `Label` down to a single glyph.
            HStack(spacing: 6) {
                heartbeat
                connection
            }
        }
        .help(helpText)
        .accessibilityLabel("Connection status")
        .accessibilityValue(helpText)
        .accessibilityHint("Opens the connection status window")
    }

    /// Beats once per received `/thump`.
    ///
    /// Driven off the heartbeat *count* rather than a timer, so it is a true
    /// report of the link: when QLab stops answering, the glyph visibly stops
    /// moving instead of continuing to animate reassuringly.
    ///
    /// With no session it shows a struck-through heart, which is a more honest
    /// readout than an empty space — the operator can see the app isn't hearing
    /// anything, rather than wonder where the indicator went.
    private var heartbeat: some View {
        Image(systemName: isLive ? "heart.fill" : "heart.slash.fill")
            .foregroundStyle(heartTint)
            // Magic replace keeps the heart itself put and draws the slash
            // across it, so losing the connection reads as this indicator going
            // quiet rather than as one glyph swapped for another.
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: client.heartbeatCount
            )
            .animation(Motion.status, value: isLive)
    }

    /// The session's state: symbol and tint both come from ``ConnectionStatus``,
    /// so this glyph, the inspector, and the display's empty state cannot
    /// disagree about what any given state looks like.
    private var connection: some View {
        Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            // `.replace` animates between two different symbols; the
            // variable-color effect conveys ongoing work while connecting, and
            // stops once settled.
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative, isActive: status.isTransitional)
            .animation(Motion.status, value: status)
    }

    private var heartTint: Color {
        guard isLive else { return .secondary }
        return client.missedThumps > 0 ? .orange : .pink
    }

    /// One tooltip for the pair, since one hover covers both glyphs. The state
    /// first, then the health behind it — the same order the inspector uses.
    private var helpText: String {
        var text = "\(status.title). \(status.detail)"
        guard isLive else { return text }

        guard client.heartbeatCount > 0 else {
            return text + " Waiting for the first heartbeat from QLab."
        }

        text += " \(client.heartbeatCount) heartbeats"
        if let round = client.lastRoundTrip {
            text += ", last round trip \((round * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
        }
        if client.missedThumps > 0 {
            text += ", \(client.missedThumps) missed"
        }
        return text + "."
    }
}

/// Toggles the keep-display-awake block.
///
/// One stable symbol, because a toolbar toggle already shows its own on state:
/// swapping the glyph as well would leave the operator guessing whether the
/// icon reports the current state or the action a click would take.
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
            Label("Keep Display Awake", systemImage: "sun.max")
        }
        .help(isOn
            ? "The display is being kept awake. Click to allow it to sleep."
            : "The display can sleep. Click to keep it awake.")
    }
}
