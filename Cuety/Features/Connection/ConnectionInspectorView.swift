import SwiftUI

struct ConnectionInspectorView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    private var server: QLabServer? {
        model.selection.flatMap { model.browser.server(withID: $0.serverID) }
    }

    private var isIdle: Bool {
        if case .offline = client.status, client.workspace == nil { return true }
        return false
    }

    var body: some View {
        if isIdle {
            ContentUnavailableView(
                client.status.title,
                systemImage: client.status.systemImage,
                description: Text(client.status.detail)
            )
        } else {
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
        }
    }


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

                Spacer(minLength: 12)

                if model.canDisconnect {
                    Button("Disconnect") {
                        model.disconnect()
                    }
                    .tint(.red)
                }
            }
            .motion(Motion.status, value: client.status)
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            LabeledContent("Server", value: server?.name ?? "—")
            LabeledContent(
                "Address",
                value: server?.address ?? "Resolved by Bonjour"
            )
            LabeledContent("Protocol", value: "TCP, SLIP-framed (OSC 1.1)")
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
            LabeledContent("Passcode") {
                Label(
                    client.usedPasscode ? "In use" : "Not required",
                    systemImage: client.usedPasscode ? "lock.fill" : "lock.open"
                )
                .foregroundStyle(client.usedPasscode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                .motion(Motion.status, value: client.usedPasscode)
            }
            LabeledContent("Access", value: client.accessLevel.title)
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
            LabeledContent("Heartbeat") {
                HeartbeatIndicator()
                    .help(client.heartbeatSummary)
            }

            if let window = client.nextThumpWindow {
                LabeledContent("Next Heartbeat") {
                    Text(.currentDate, format: .timer(
                        countingDownIn: window, showsHours: false, maxFieldCount: 2
                    ))
                    .monospacedDigit()
                }
                .help("Time until Cuety sends QLab its next heartbeat.")
            }

            if let round = client.lastRoundTrip {
                LabeledContent("Round Trip", value: formatMilliseconds(round))
            }
            if let mean = client.meanRoundTrip {
                LabeledContent("Mean Round Trip", value: formatMilliseconds(mean))
            }

            if client.missedThumps > 0 {
                LabeledContent("Missed Heartbeats") {
                    Text(client.missedThumps.formatted())
                        .foregroundStyle(.orange)
                }
            }

            LabeledContent("Sent", value: traffic(
                messages: model.log.totalSent, bytes: model.log.bytesSent
            ))
            LabeledContent("Received", value: traffic(
                messages: model.log.totalReceived, bytes: model.log.bytesReceived
            ))

            if model.log.totalMalformed > 0 {
                LabeledContent("Malformed Packets") {
                    Text(model.log.totalMalformed.formatted())
                        .foregroundStyle(.orange)
                }
            }

            if client.reconnectCount > 0 {
                LabeledContent("Reconnections", value: client.reconnectCount.formatted())
            }

            if client.droppedEventCount > 0 {
                LabeledContent("Dropped Events") {
                    Text(client.droppedEventCount.formatted())
                        .foregroundStyle(.orange)
                }
                .help("""
                QLab sent updates faster than Cuety could read them, so some \
                were lost. Cuety refetched the cue data to catch up, and \
                rebuilds the session if it happens again straight away.
                """)
            }

            if client.lateReplyCount > 0 {
                LabeledContent("Late Replies") {
                    Text(client.lateReplyCount.formatted())
                        .foregroundStyle(.orange)
                }
                .help("""
                QLab answered these after Cuety had stopped waiting, so they \
                were discarded rather than mistaken for the answer to a later \
                request. A rising count means the request timeout is shorter \
                than this QLab needs.
                """)
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


    private var totalCueCount: Int {
        func count(_ cues: [Cue]) -> Int {
            cues.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(client.cueLists)
    }

    private var watchedCueListName: String? {
        guard let id = client.watchedCueListID else { return nil }
        return client.cueLists.first { $0.uniqueID == id }?.displayName
    }

    private func traffic(messages: Int, bytes: Int) -> String {
        let count = messages.formatted()
        let size = bytes.formatted(.byteCount(style: .memory))
        return "\(count) messages · \(size)"
    }

    private func formatMilliseconds(_ interval: TimeInterval) -> String {
        (interval * 1000).formatted(.number.precision(.fractionLength(1))) + " ms"
    }
}

#Preview {
    ConnectionInspectorView()
        .environment(AppModel())
        .frame(width: 460, height: 620)
}
