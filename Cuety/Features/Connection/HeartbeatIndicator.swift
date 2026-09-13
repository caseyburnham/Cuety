import SwiftUI

/// The heartbeat glyph: beats once per received `/thump`.
///
/// Shared by the toolbar's Activity Log button and the connection inspector's
/// Health section, so the two cannot disagree about whether Cuety is hearing
/// anything. The inspector used to report a bare count instead — a number that
/// tells you how many heartbeats have arrived but not whether one is arriving
/// *now*, which is the question being asked.
///
/// Carries no tooltip or accessibility label of its own: the Activity Log
/// button's tooltip has a window to name as well as a heartbeat to describe,
/// so each call site composes its own from ``QLabClient/heartbeatSummary``.
struct HeartbeatIndicator: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    /// Whether there's a session that could produce a heartbeat at all.
    private var isLive: Bool { client.status.hasLiveData }

    var body: some View {
        // Driven off the heartbeat *count* rather than a timer, so it is a true
        // report of the link: when QLab stops answering, the glyph visibly
        // stops moving instead of continuing to animate reassuringly.
        //
        // With no session it shows a struck-through heart, which is a more
        // honest readout than an empty space — the operator can see the app
        // isn't hearing anything, rather than wonder where the indicator went.
        Image(systemName: isLive ? "heart.fill" : "heart.slash.fill")
            .foregroundStyle(tint)
            // Magic replace keeps the heart itself put and draws the slash
            // across it, so losing the connection reads as this indicator going
            // quiet rather than as one glyph swapped for another.
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: client.heartbeatCount
            )
            .motion(Motion.status, value: isLive)
    }

    private var tint: Color {
        guard isLive else { return .secondary }
        return client.missedThumps > 0 ? .orange : .pink
    }
}

extension QLabClient {
    /// A sentence describing the heartbeat, including the running total.
    ///
    /// Presentation on the client for the same reason ``ConnectionStatus``
    /// carries its own phrasing: the toolbar glyph and the inspector describe
    /// one fact, and writing it twice is how they come to disagree.
    var heartbeatSummary: String {
        guard status.hasLiveData else { return "Not receiving heartbeats from QLab." }
        var text = "Receiving heartbeats from QLab."

        guard heartbeatCount > 0 else {
            return text + " Waiting for the first heartbeat from QLab."
        }

        text += " \(heartbeatCount.formatted()) heartbeats"
        if let round = lastRoundTrip {
            text += ", last round trip \((round * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
        }
        if missedThumps > 0 {
            text += ", \(missedThumps) missed"
        }
        return text + "."
    }
}
