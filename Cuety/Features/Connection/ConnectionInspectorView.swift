import Network
import SwiftUI

/// Detailed transport, session, and health information for the current connection.
///
/// Grouped into five sections that answer five different questions: where are
/// we connected, what did we negotiate, what is QLab, how healthy is the link,
/// and what went wrong last.
struct ConnectionInspectorView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    var body: some View {
        Form {
            statusSection

            if client.status.hasLiveData || client.workspace != nil {
                transportSection
                sessionSection
                qlabSection
                healthSection
            }

            if client.lastErrorDescription != nil {
                errorSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection Status")
        .overlay {
            if case .offline = client.status, client.workspace == nil {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "network.slash",
                    description: Text(client.status.detail)
                )
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: client.status.systemImage)
                    .font(.title2)
                    .foregroundStyle(client.status.tint)
                    .symbolEffect(
                        .variableColor.iterative,
                        isActive: client.status.isTransitional
                    )
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 2) {
                    Text(client.status.title)
                        .font(.headline)
                    Text(client.status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .animation(Motion.status, value: client.status)
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            LabeledContent("Server", value: serverDescription)
            LabeledContent("Protocol", value: "TCP, SLIP-framed (OSC 1.1)")
            if let since = client.connectedSince {
                LabeledContent("Connected") {
                    Text(since, format: .relative(presentation: .named))
                }
            }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            if let workspace = client.workspace {
                LabeledContent("Workspace", value: workspace.displayName)
                LabeledContent("Workspace ID") {
                    Text(workspace.uniqueID)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
                if let port = workspace.port {
                    LabeledContent("Listening Port", value: String(port))
                }
            }
            LabeledContent("Passcode", value: client.usedPasscode ? "In use" : "Not required")
            LabeledContent(
                "Update Subscription",
                value: client.isSubscribedToUpdates ? "Active" : "Inactive"
            )
        }
    }

    private var qlabSection: some View {
        Section("QLab") {
            LabeledContent("Version", value: client.qlabVersion ?? "Unknown")
            LabeledContent("Cue Lists", value: client.cueLists.count.formatted())
            LabeledContent("Cues", value: totalCueCount.formatted())
            if let watched = watchedCueListName {
                LabeledContent("Watching", value: watched)
            }
        }
    }

    private var healthSection: some View {
        Section("Health") {
            LabeledContent("Heartbeats", value: client.heartbeatCount.formatted())

            if let last = client.lastThumpDate {
                LabeledContent("Last Heartbeat") {
                    Text(last, format: .relative(presentation: .numeric))
                        .monospacedDigit()
                }
            }

            if let round = client.lastRoundTrip {
                LabeledContent("Round Trip", value: formatMilliseconds(round))
            }
            if let mean = client.meanRoundTrip {
                LabeledContent("Round Trip (mean)", value: formatMilliseconds(mean))
            }

            if client.missedThumps > 0 {
                LabeledContent("Missed Heartbeats") {
                    Text(client.missedThumps.formatted())
                        .foregroundStyle(.orange)
                }
            }

            LabeledContent("Messages") {
                Text("↑ \(model.log.totalSent)   ↓ \(model.log.totalReceived)")
                    .monospacedDigit()
            }
            LabeledContent("Data") {
                Text(
                    "↑ \(model.log.bytesSent.formatted(.byteCount(style: .memory)))   "
                    + "↓ \(model.log.bytesReceived.formatted(.byteCount(style: .memory)))"
                )
                .monospacedDigit()
            }

            if model.log.totalMalformed > 0 {
                LabeledContent("Malformed Packets") {
                    Text(model.log.totalMalformed.formatted())
                        .foregroundStyle(.orange)
                }
            }

            if client.reconnectCount > 0 {
                LabeledContent("Reconnections", value: client.reconnectCount.formatted())
            }
        }
    }

    private var errorSection: some View {
        Section("Last Error") {
            if let description = client.lastErrorDescription {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = client.lastErrorDate {
                LabeledContent("Occurred") {
                    Text(date, format: .relative(presentation: .named))
                }
            }
        }
    }

    // MARK: - Derived values

    private var serverDescription: String {
        guard let workspace = client.workspace else { return "—" }
        if let port = workspace.port {
            return "\(workspace.displayName) : \(port)"
        }
        return workspace.displayName
    }

    private var totalCueCount: Int {
        func count(_ cues: [Cue]) -> Int {
            cues.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(client.cueLists)
    }

    private var watchedCueListName: String? {
        guard let id = client.watchedCueListID else { return nil }
        return client.cueLists.first { $0.uniqueID == id }?.name
    }

    /// Round trips on a LAN are sub-millisecond to single-digit milliseconds,
    /// so milliseconds with one decimal is the readable unit.
    private func formatMilliseconds(_ interval: TimeInterval) -> String {
        (interval * 1000).formatted(.number.precision(.fractionLength(1))) + " ms"
    }
}

#Preview {
    ConnectionInspectorView()
        .environment(AppModel())
        .frame(width: 460, height: 620)
}
