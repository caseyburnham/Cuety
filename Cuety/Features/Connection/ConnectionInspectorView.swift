import SwiftUI

/// Detailed transport, session, and health information for the current connection.
///
/// Grouped into five sections that answer five different questions: where are
/// we connected, what did we negotiate, what is QLab, how healthy is the link,
/// and what went wrong last.
struct ConnectionInspectorView: View {
    @Environment(AppModel.self) private var model

    private var client: QLabClient { model.client }

    /// The server behind the current session, for the facts that belong to the
    /// machine rather than to the workspace on it.
    private var server: QLabServer? {
        model.selection.flatMap { model.browser.server(withID: $0.serverID) }
    }

    /// Nothing has been attempted yet, so there are no details to show.
    private var isIdle: Bool {
        if case .offline = client.status, client.workspace == nil { return true }
        return false
    }

    var body: some View {
        // An `if`, not an overlay: laying the empty state *over* a populated
        // Form left the status section showing through behind it.
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

    // MARK: - Sections

    /// The glyph, the state, and the one action that acts on it, on a single
    /// centred line.
    ///
    /// All three are vertically centred against each other rather than pinned
    /// to the top: the glyph and the button are one item each, so top-aligning
    /// them against a two-line block left both sitting high with the detail
    /// line hanging below. Disconnect is in this row at all because it acts on
    /// the thing the row names — as its own row beneath, it read as one more
    /// fact about the session.
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
                    // Tinted red rather than given a destructive role:
                    // dropping the connection loses nothing and is a click
                    // away from being undone, so the colour is there to make
                    // it findable, not to warn.
                    //
                    // The condition is ``AppModel/canDisconnect``, not a third
                    // opinion of its own. This used to ask whether a workspace
                    // had been negotiated, which is neither what the menu asked
                    // nor what the sidebar asked.
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
                // A Bonjour service has no address of ours to report: the
                // system resolves it at connect time.
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
            // A glyph as well as the words, because this is the one row in the
            // section an operator scans for: a padlock reads at a glance where
            // "In use" has to be read.
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
            // The same beating glyph the toolbar shows, rather than a count of
            // beats: whether one is arriving *now* is the question, and the
            // running total is a detail the tooltip can carry.
            LabeledContent("Heartbeat") {
                HeartbeatIndicator()
                    .help(client.heartbeatSummary)
            }

            // Counting down to the next one rather than up from the last.
            //
            // `.relative` on the last heartbeat rendered once, at the moment
            // the view was built — and the only thing that rebuilt that row was
            // a heartbeat arriving, at which point the answer is always zero.
            // Hence "in 0 seconds", for ever, with the sign wrong too.
            //
            // A `SystemFormatStyle` fed `.currentDate` reschedules its own
            // updates as the clock advances, and `.timer(countingDownIn:)`
            // clamps at `0:00` once the deadline passes — so a QLab that has
            // stopped answering shows a countdown stuck at zero beside a
            // rising Missed Heartbeats, rather than a number that keeps
            // climbing as though something were still happening.
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

            // One row per direction, each pairing the count with the bytes it
            // accounts for. Two labelled rows say what a single row of arrow
            // characters only implied.
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

            // Only when it has happened. A permanent "Late Replies: 0" row
            // would be one more number to scan past on a healthy session.
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

    // MARK: - Derived values

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
