import SwiftUI

/// The three status glyphs in the upper trailing corner.
///
/// One `GlassEffectContainer` holds all three so they blend as a single control
/// cluster, per Apple's guidance to group glass effects rather than scatter them.
struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HeartbeatGlyph()
                    .glassEffectID("heartbeat", in: glassNamespace)

                KeepAwakeGlyph()
                    .glassEffectID("keepawake", in: glassNamespace)

                StatusGlyph()
                    .glassEffectID("status", in: glassNamespace)
            }
        }
        .padding(.trailing, 20)
        .padding(.top, 14)
    }
}

/// Connection status, as a glyph that changes with a symbol-replace transition.
struct StatusGlyph: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var status: ConnectionStatus { model.client.status }

    var body: some View {
        Button {
            openWindow(id: WindowID.connectionInspector.rawValue)
        } label: {
            Image(systemName: status.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status.tint)
                // `.replace` animates between two different symbols; the
                // variable-color effect conveys ongoing work while browsing or
                // connecting, and stops once settled.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: status.isTransitional)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .padding(6)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(Motion.status, value: status)
        .help("\(status.title). \(status.detail)")
        .accessibilityLabel("Connection status: \(status.title)")
        .accessibilityHint("Opens the connection status window")
    }
}

/// Beats once per received `/thump`.
///
/// The beat is driven off the heartbeat *count* rather than a timer, so it is a
/// true report of the link: when QLab stops answering, the glyph visibly stops
/// moving instead of continuing to animate reassuringly.
struct HeartbeatGlyph: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    /// Hidden entirely when there's no session to have a heartbeat.
    private var isRelevant: Bool { client.status.hasLiveData }

    var body: some View {
        if isRelevant {
            Image(systemName: "heart.fill")
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: client.heartbeatCount
                )
                .frame(width: 26, height: 26)
                .padding(6)
                .glassEffect(.regular, in: .circle)
                .help(helpText)
                .accessibilityLabel("Heartbeat")
                .accessibilityValue(helpText)
                .transition(.opacity.combined(with: .scale))
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
struct KeepAwakeGlyph: View {
    @Environment(AppModel.self) private var model

    private var isOn: Bool { model.preferences.keepsDisplayAwake }

    var body: some View {
        Button {
            withAnimation(Motion.status) {
                model.toggleKeepAwake()
            }
        } label: {
            Image(systemName: isOn ? "sun.max.fill" : "moon.zzz.fill")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? .yellow : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .padding(6)
        .glassEffect(
            isOn ? .regular.tint(.yellow.opacity(0.25)).interactive() : .regular.interactive(),
            in: .circle
        )
        .help(isOn
            ? "The display is being kept awake. Click to allow it to sleep."
            : "The display can sleep. Click to keep it awake.")
        .accessibilityLabel("Keep display awake")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom)
        VStack {
            HStack {
                Spacer()
                HeaderBar()
            }
            Spacer()
        }
    }
    .environment(AppModel())
    .frame(width: 600, height: 300)
}
