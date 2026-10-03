import SwiftUI

struct EventHistoryView: View {
    @Environment(AppModel.self) private var model

    private var statistics: ShowStatistics { model.client.statistics }

    var body: some View {
        List {
            if statistics.isIncomplete || model.isDataStale {
                Label("Activity incomplete", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            ForEach(statistics.recentEvents.reversed()) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(for: event.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.kind.rawValue).font(.headline)
                        if let detail = event.detail ?? (event.cueLabel.isEmpty ? nil : event.cueLabel) {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let workspaceName = event.workspaceName {
                            Text(workspaceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(event.timestamp, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                        Text(event.timestamp, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
        }
        .overlay {
            if statistics.recentEvents.isEmpty {
                ContentUnavailableView("No Events", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func symbol(for kind: ShowStatistics.Event.Kind) -> String {
        switch kind {
        case .go: "play.fill"
        case .start: "play.circle"
        case .stop: "stop.fill"
        case .panic: "exclamationmark.octagon"
        case .connecting: "network"
        case .connected: "checkmark.circle"
        case .disconnected: "circle.slash"
        case .connectionLost, .connectionFailed: "exclamationmark.triangle"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .workspaceClosed: "rectangle.badge.xmark"
        case .passcodeRequired, .passcodeRejected: "lock"
        case .missedEvents: "clock.badge.exclamationmark"
        }
    }
}
