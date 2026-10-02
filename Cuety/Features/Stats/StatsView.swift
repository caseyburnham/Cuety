import SwiftUI
import Charts

struct StatsView: View {
    @Environment(AppModel.self) private var model

    private var statistics: ShowStatistics { model.client.statistics }

    private var activityMinutes: [(minute: Date, count: Int)] {
        let events = statistics.recentEvents.filter { $0.kind == .go || $0.kind == .start }
        let groups = Dictionary(grouping: events) { event in
            Date(timeIntervalSince1970: floor(event.timestamp.timeIntervalSince1970 / 60) * 60)
        }
        return groups.map { (minute: $0.key, count: $0.value.count) }.sorted { $0.minute < $1.minute }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    var body: some View {
        Form {
            Section {
                Label(model.client.status.title, systemImage: model.client.status.systemImage)
                    .foregroundStyle(model.client.status.tint)
                Text("Counts cover broadcasts observed during this connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if statistics.isIncomplete || model.isDataStale {
                    Label("Some activity may be missing", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !model.hasCurrentCueData {
                    Text("Monitoring is not current.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Show odometer") {
                LabeledContent("GO events", value: statistics.goCount.formatted())
                LabeledContent("Cue start events", value: statistics.startCount.formatted())
                LabeledContent("Distinct cues in GO / start events", value: statistics.uniqueCueCount.formatted())
                LabeledContent("Cue stops", value: statistics.stopCount.formatted())
                LabeledContent("Panics", value: statistics.panicCount.formatted())
                if let startedAt = statistics.startedAt {
                    LabeledContent("Monitoring began") {
                        Text(startedAt, format: .dateTime.hour().minute().second())
                    }
                }
                if let startedAt = statistics.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("Monitoring duration", value: elapsed(from: startedAt, to: statistics.endedAt ?? context.date))
                    }
                }
                if let lastGO = statistics.lastGO {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent(statistics.isIncomplete ? "Time since last observed GO" : "Time since last GO", value: elapsed(from: lastGO, to: statistics.endedAt ?? context.date))
                            .monospacedDigit()
                    }
                } else {
                    LabeledContent("Time since last GO", value: "No GO observed")
                }
            }

            Section {
                Text("\(statistics.gosSinceLastPanic.formatted()) GOs since \(statistics.lastPanic == nil ? "monitoring began" : "last panic")")

                    .monospacedDigit()
                if statistics.lastPanic == nil {
                    Text("No panic observed yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recent activity") {
                if !statistics.recentEvents.isEmpty {
                    Chart(activityMinutes, id: \.minute) { bucket in
                        BarMark(x: .value("Minute", bucket.minute, unit: .minute), y: .value("GO / start events", bucket.count))
                    }
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 100)
                    .accessibilityLabel("Recent GO and start events per minute")
                }
                Text("Chart covers the most recent 100 observed events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}
