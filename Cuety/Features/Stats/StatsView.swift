import SwiftUI
import Charts

struct StatsView: View {
    @Environment(AppModel.self) private var model

    private var statistics: ShowStatistics { model.client.statistics }

    private var activityMinutes: [(minute: Date, count: Int)] {
        let events = statistics.currentObservationEvents.filter { $0.kind == .go || $0.kind == .start }
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
                if statistics.isIncomplete || model.isDataStale {
                    Label("Activity incomplete", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("GOs since last panic") {
                    Text(statistics.gosSinceLastPanic.formatted())
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }

            Section {
                field("GO events", value: statistics.goCount.formatted())
                field("Cue start events", value: statistics.startCount.formatted())
                field("Distinct cues", value: statistics.uniqueCueCount.formatted())
                field("Cue stops", value: statistics.stopCount.formatted())
                field("Panics", value: statistics.panicCount.formatted())
            } header: {
                Label("This Connection", systemImage: "chart.bar")
            }

            Section {
                if let startedAt = statistics.startedAt {
                    LabeledContent("Monitoring began") {
                        Text(startedAt, format: .dateTime.hour().minute().second())
                            .textSelection(.enabled)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        field("Monitoring duration", value: elapsed(from: startedAt, to: statistics.endedAt ?? context.date))
                    }
                }
                if let lastGO = statistics.lastGO {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        field("Time since last GO", value: elapsed(from: lastGO, to: statistics.endedAt ?? context.date))
                    }
                } else {
                    field("Time since last GO", value: "—")
                }
            } header: {
                Label("Timing", systemImage: "clock")
            }

            Section {
                if !activityMinutes.isEmpty {
                    Chart(activityMinutes, id: \.minute) { bucket in
                        BarMark(x: .value("Minute", bucket.minute, unit: .minute), y: .value("GO / start events", bucket.count))
                    }
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 100)
                    .accessibilityLabel("Recent GO and start events per minute")
                } else {
                    Text("No cue activity")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Recent Activity", systemImage: "waveform.path")
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }
}
