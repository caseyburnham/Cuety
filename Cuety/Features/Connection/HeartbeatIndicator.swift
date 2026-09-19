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
