import SwiftUI

struct HeartbeatIndicator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var client: QLabClient { model.client }

    private var isLive: Bool { client.status.hasLiveData }

    var body: some View {
        Image(systemName: client.heartbeatSymbol)
            .foregroundStyle(client.heartbeatTint)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: reduceMotion ? 0 : client.heartbeatCount
            )
            .motion(Motion.status, value: isLive)
    }
}

extension QLabClient {
    var heartbeatSymbol: String {
        status.hasLiveData ? "heart.fill" : "heart.slash.fill"
    }

    var heartbeatTint: Color {
        guard status.hasLiveData else { return .secondary }
        return missedThumps > 0 ? .orange : .pink
    }

    var heartbeatSummary: String {
        guard status.hasLiveData else { return "Not receiving heartbeats from QLab." }
        guard heartbeatCount > 0 else { return "Waiting for QLab’s first heartbeat." }

        var lines = ["Receiving heartbeats from QLab: \(heartbeatCount.formatted()) so far."]
        if let roundTrip = lastRoundTrip {
            let milliseconds = (roundTrip * 1000).formatted(.number.precision(.fractionLength(1)))
            lines.append("Last heartbeat: \(milliseconds) ms round trip.")
        }
        if missedThumps > 0 {
            lines.append("Missed in a row: \(missedThumps).")
        }
        return lines.joined(separator: " ")
    }
}
