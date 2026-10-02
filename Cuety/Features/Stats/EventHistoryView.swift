import SwiftUI

struct EventHistoryView: View {
    @Environment(AppModel.self) private var model

    private var statistics: ShowStatistics { model.client.statistics }

    var body: some View {
        List {
            Section {
                if statistics.isIncomplete || model.isDataStale {
                    Label("Some activity may be missing", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !model.hasCurrentCueData {
                    Text("Monitoring is not current. Retained events describe previously observed activity.")
                        .foregroundStyle(.secondary)
                }
                Text("The most recent 100 observed events, newest first. Reconnecting starts a new history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Events") {
                if statistics.recentEvents.isEmpty {
                    Text("Waiting for show activity.").foregroundStyle(.secondary)
                } else {
                    ForEach(statistics.recentEvents.reversed()) { event in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(event.kind.rawValue).font(.headline)
                                if !event.cueLabel.isEmpty {
                                    Text(event.cueLabel).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}
