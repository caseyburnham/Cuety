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

        // One `ToolbarItem` per button, rather than one item wrapping a view
        // that returns both.
        //
        // These used to be a single `ConnectionStatusIndicator` whose body was
        // a `Group` of two buttons inside one `ToolbarItemGroup`. The toolbar
        // then saw *one* item holding custom content instead of two toolbar
        // buttons, and custom content does not get the standard toolbar button
        // treatment — the Liquid Glass press response included. Each button is
        // now the direct content of its own item, which is how a toolbar is
        // meant to be composed.
        ToolbarItem(placement: .primaryAction) {
            ActivityLogButton()
        }

        ToolbarItem(placement: .primaryAction) {
            ConnectionStatusButton()
        }
    }
}

/// Opens the Activity Log, and beats once per received heartbeat.
struct ActivityLogButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var client: QLabClient { model.client }

    var body: some View {
        Button {
            openWindow(id: WindowID.activityLog.rawValue)
        } label: {
            // The same indicator the connection inspector shows. It used to
            // live here, which meant the inspector had nothing to mirror.
            HeartbeatIndicator()
        }
        .help("Activity Log. " + client.heartbeatSummary)
        .accessibilityLabel("Activity Log")
        .accessibilityValue(client.heartbeatSummary)
        .accessibilityHint("Opens the activity log")
    }
}

/// Opens the connection inspector, and reports the session's state.
struct ConnectionStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var status: ConnectionStatus { model.client.status }

    var body: some View {
        Button {
            openWindow(id: WindowID.connectionInspector.rawValue)
        } label: {
            // Symbol and tint both come from ``ConnectionStatus``, so this
            // glyph, the inspector, and the display's empty state cannot
            // disagree about what any given state looks like.
            Image(systemName: connectionSymbol)
                .foregroundStyle(status.tint)
                // `.replace` animates between two different symbols; the
                // variable-color effect conveys ongoing work while connecting,
                // and stops once settled.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: status.isTransitional)
                .motion(Motion.status, value: status)
        }
        .help("\(status.title). \(status.detail)")
        .accessibilityLabel("Connection status")
        .accessibilityValue(status.title)
        .accessibilityHint("Opens the connection status window")
    }

    /// Only `needsPasscode` differs from ``ConnectionStatus/systemImage``: a
    /// filled lock carries further in a toolbar than the outlined circle the
    /// inspector uses. The offline case used to be overridden too, with the
    /// identical glyph — so changing the status type's symbol left the toolbar
    /// showing the old one.
    private var connectionSymbol: String {
        if case .needsPasscode = status { return "lock.fill" }
        return status.systemImage
    }
}

/// Toggles the keep-display-awake block.
///
/// The glyph brightens with the state: `sun.min` when the display is free to
/// sleep, `sun.max.fill` when it is being held awake, magic-replaced between
/// the two so the rays grow rather than one symbol cutting to another.
///
/// This reverses an earlier decision to keep one stable symbol, on the
/// reasoning that a toolbar toggle already shows its own on state and a
/// changing glyph might read as the *action* rather than the state. In
/// practice the brightness reads as state immediately — dim sun, bright sun —
/// and the on state is the thing worth being able to see from across a booth.
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
            Label {
                Text("Keep Display Awake")
            } icon: {
                Image(systemName: isOn ? "sun.max.fill" : "sun.min")
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
            }
        }
        .motion(Motion.status, value: isOn)
        .help(isOn
            ? "The display is being kept awake."
            : "The display can sleep.")
    }
}
