import Foundation
import Network
import Testing
@testable import Cuety

@Suite("Session authorization")
@MainActor
struct QLabSessionTests {
    private func message(_ address: String, status: String, data: String) -> OSCMessage {
        OSCMessage("/reply" + address, [.string(
            "{\"address\":\"\(address)\",\"status\":\"\(status)\",\"data\":\(data)}"
        )])
    }

    @Test("Denied heartbeat revokes authorization even with a thump payload")
    func deniedHeartbeat() throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompted = false
        client.onPasscodeRequired = { _ in prompted = true }
        #expect(throws: QLabClient.RequestFailure.self) {
            _ = try client.validateSessionReply(
                message("/workspace/W/thump", status: "denied", data: "\"thump\""),
                as: String.self
            )
        }
        #expect(prompted)
        #expect(client.status == .needsPasscode(rejected: false))
        #expect(!client.status.hasLiveData)
        #expect(client.heartbeatCount == 0)
        #expect(!client.isSubscribedToUpdates)
    }

    @Test("Denied cue lists prompt before attempting to decode the error payload")
    func deniedCueLists() throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompted = false
        client.onPasscodeRequired = { _ in prompted = true }
        #expect(throws: QLabClient.RequestFailure.self) {
            _ = try client.validateSessionReply(
                message("/workspace/W/cueLists", status: "denied", data: "\"denied\""),
                as: [Cue].self
            )
        }
        #expect(prompted)
        #expect(!client.status.hasLiveData)
        #expect(client.cueLists.isEmpty)
        #expect(client.workspace == nil)
    }

    @Test("A second denial does not raise a second prompt")
    func repeatedDenialsPromptOnce() throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompts = 0
        client.onPasscodeRequired = { _ in prompts += 1 }
        for _ in 0..<3 {
            #expect(throws: QLabClient.RequestFailure.self) {
                _ = try client.validateSessionReply(
                    message("/workspace/W/thump", status: "denied", data: "\"thump\""),
                    as: String.self
                )
            }
        }
        // Every request in flight comes back denied when QLab starts refusing
        // them. Only the first is news; the rest would rebuild the sheet and
        // lose what it was already saying.
        #expect(prompts == 1)
    }

    @Test("Failed setup requests cannot masquerade as successful empty replies",
          arguments: ["/updates", "/listen/playhead", "/workspace/W/cueLists"])
    func failedSetup(address: String) {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        #expect(throws: QLabClient.RequestFailure.self) {
            _ = try client.validateSessionReply(
                message(address, status: "error", data: "null"), as: QLabEmptyPayload.self
            )
        }
    }

    @Test("An authorized empty cue list remains valid")
    func emptyCueLists() throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        let reply = try client.validateSessionReply(
            message("/workspace/W/cueLists", status: "ok", data: "[]"), as: [Cue].self
        )
        #expect(reply.data?.isEmpty == true)
        #expect(client.status == .offline)
    }
}

@Suite("Live session authorization", .serialized)
@MainActor
struct QLabLiveAuthorizationTests {
    @Test("A changed passcode revokes a connected session and permits an explicit retry")
    func changedPasscode() async throws {
        let peer = try AuthorizationPeer()
        defer { peer.stop() }
        let port = try await peer.start()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.heartbeatInterval = 0.05
        let client = QLabClient(preferences: preferences, log: ActivityLog())
        defer { client.disconnect() }
        var prompts = 0
        client.onPasscodeRequired = { _ in prompts += 1 }
        let server = QLabServer.localhost(port: port)
        await client.connect(to: server, workspaceID: "W", passcode: "old")
        try #require(client.status == .connected)
        peer.denyHeartbeat = true
        let deadline = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.status == .needsPasscode(rejected: true))
        #expect(prompts == 1)
        #expect(client.workspace == nil)
        #expect(client.cueLists.isEmpty)
        // A passcode is the operator's to supply, so nothing should be quietly
        // reconnecting behind the sheet.
        #expect(!client.isSessionActive)
        peer.denyHeartbeat = false
        await client.connect(to: server, workspaceID: "W", passcode: "new")
        #expect(client.status == .connected)
    }

    @Test("Denied cue lists after connect never establish a live session")
    func deniedInitialLists() async throws {
        let peer = try AuthorizationPeer()
        peer.denyCueLists = true
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: "old")
        #expect(client.status == .needsPasscode(rejected: true))
        #expect(client.connectedSince == nil)
        #expect(!client.isSubscribedToUpdates)
    }
}

@Suite("Losing the connection", .serialized)
@MainActor
struct QLabDisconnectTests {
    private func makePreferences(requestTimeout: TimeInterval = 5) throws -> Preferences {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.requestTimeout = requestTimeout
        return preferences
    }

    @Test("A server that accepts the socket but never answers fails instead of hanging")
    func muteServerFailsRatherThanHanging() async throws {
        let peer = try AuthorizationPeer()
        peer.isMute = true
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 0.4), log: ActivityLog()
        )
        defer { client.disconnect() }

        let started = ContinuousClock.now
        await #expect(throws: QLabClient.RequestFailure.self) {
            _ = try await client.fetchWorkspaces(from: .localhost(port: port))
        }
        // The bound is the point, not the error. A deadline compared inside
        // the event loop never fires once the peer stops sending events, so
        // the sidebar refresh waiting on this used to hang for good.
        #expect(started.duration(to: .now) < .seconds(3))
    }

    /// A show with cues in it and a playhead parked on one of them.
    ///
    /// Every disconnect assertion about cue data is vacuous against an empty
    /// workspace — which is how a drop that retained the whole cue tree passed
    /// a test asserting the tree was cleared.
    private static let populatedShow: [AuthorizationPeer.CueListStub] = [
        .init(
            id: "L1",
            name: "Main",
            cues: [
                .init(id: "C1", number: "1", name: "House to Half"),
                .init(id: "C2", number: "2", name: "Thunder Crash"),
            ],
            playheadCueID: "C1"
        ),
    ]

    @Test("A QLab that quits leaves a session that is visibly retrying")
    func quitPeerLeavesSessionRetrying() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 0.3), log: ActivityLog()
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)
        try #require(!client.cueLists.isEmpty)

        peer.stop()

        let dropped = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < dropped {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!client.status.hasLiveData)
        #expect(client.cueLists.isEmpty)
        // Still Cuety's session to recover, so the operator is offered a way
        // to stop it rather than a Connect button for something already being
        // connected to.
        #expect(client.isSessionActive)

        // A refused or unresolvable endpoint parks `NWConnection` in
        // `.waiting` and reports no failure at all, so the attempt has to be
        // bounded by a deadline of Cuety's own. Reaching a second attempt is
        // what proves the first one gave up rather than sitting in
        // `connecting` for the rest of the show.
        var reachedAttempt = 0
        let retried = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < retried {
            if case .reconnecting(let attempt, _) = client.status, attempt >= 2 {
                reachedAttempt = attempt
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reachedAttempt >= 2)
    }

    @Test("A workspace QLab has closed ends the session for good")
    func closedWorkspaceEndsSession() async throws {
        let peer = try AuthorizationPeer()
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        var ended: [QLabClient.SessionEnd] = []
        client.onSessionEnded = { ended.append($0) }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        peer.push(OSCMessage("/update/workspace/W/disconnect"))

        let deadline = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.status == .workspaceClosed)
        #expect(ended == [.workspaceClosed])
        // Terminal, and it has to stay that way: QLab is answering fine, so a
        // reconnect would keep succeeding at connecting and failing at finding
        // anything to connect to.
        #expect(!client.isSessionActive)
        try await Task.sleep(for: .milliseconds(900))
        #expect(client.status == .workspaceClosed)
    }

    @Test("A workspace missing from /workspaces is reported closed, not retried")
    func missingWorkspaceIsNotRetried() async throws {
        let peer = try AuthorizationPeer()
        peer.openWorkspaceIDs = []
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }

        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)

        #expect(client.status == .workspaceClosed)
        #expect(!client.isSessionActive)
    }

    @Test("A drop stops presenting the cue that was on screen as live")
    func dropInvalidatesCueDataOnScreen() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 0.3), log: ActivityLog()
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)
        // There has to be a cue on the display for its disappearance to mean
        // anything. This is the requirement the old disconnect test lacked.
        try #require(client.playheadCue?.uniqueID == "C1")

        peer.stop()

        let deadline = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        // Not one of these survives a drop: the cue tree, the playhead that
        // pointed into it, the list the display was following, or the two
        // session claims that only hold while the socket is up.
        #expect(!client.status.hasLiveData)
        #expect(client.cueLists.isEmpty)
        #expect(client.playheads.isEmpty)
        #expect(client.watchedCueListID == nil)
        #expect(client.currentPlayheadCueID == nil)
        #expect(client.playheadCue == nil)
        #expect(client.watchedGraph == nil)
        #expect(!client.isSubscribedToUpdates)
        #expect(client.connectedSince == nil)
    }

    @Test("A reconnect repopulates the display without a manual refresh")
    func reconnectRepopulatesCueData() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.playheadCue?.uniqueID == "C1")

        // The other half of the contract: invalidating on a drop is only safe
        // if getting the session back puts the cue tree, the playhead and the
        // watched list back too.
        await client.reconnect()

        #expect(client.status == .connected)
        #expect(client.watchedCueListID == "L1")
        #expect(client.currentPlayheadCueID == "C1")
        #expect(client.playheadCue?.displayNumber == "1")
        #expect(client.isSubscribedToUpdates)
        #expect(client.connectedSince != nil)
    }

    @Test("Cancelling a workspace probe fails it at once, not at its deadline")
    func cancellingProbeFailsPromptly() async throws {
        let peer = try AuthorizationPeer()
        peer.isMute = true
        defer { peer.stop() }
        let port = try await peer.start()
        // Deliberately generous, so waiting the timeout out is unmistakably
        // different from being cancelled.
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 5), log: ActivityLog()
        )
        defer { client.disconnect() }

        let started = ContinuousClock.now
        let probe = Task { try await client.fetchWorkspaces(from: .localhost(port: port)) }
        try await Task.sleep(for: .milliseconds(100))
        probe.cancel()

        await #expect(throws: CancellationError.self) { _ = try await probe.value }
        // A cancelled probe must not report itself as a QLab timeout either —
        // that put "QLab did not answer" against a server nobody had finished
        // asking.
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("Cancelling an awaited session request stops it at once")
    func cancellingSessionRequestFailsPromptly() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 5), log: ActivityLog()
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        // QLab has gone quiet on this one address: the request goes out and is
        // simply never answered.
        peer.withholdRepliesTo = ["cueLists"]

        let started = ContinuousClock.now
        let refresh = Task { try await client.refreshCueLists() }
        try await Task.sleep(for: .milliseconds(100))
        refresh.cancel()

        // The request layer installed no cancellation handler before, so this
        // sat suspended for the whole five seconds with its bookkeeping intact.
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("A reply arriving after its request timed out is dropped, not reused")
    func lateReplyIsNotGivenToALaterRequest() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let preferences = try makePreferences(requestTimeout: 0.4)
        preferences.heartbeatInterval = 0.05
        let client = QLabClient(preferences: preferences, log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        // The heartbeat asks the same address over and over, which is exactly
        // where a late reply can be mistaken for a newer request's answer:
        // every `/thump` reply looks identical.
        peer.withholdRepliesTo = ["thump"]

        let missed = ContinuousClock.now + .seconds(3)
        while client.missedThumps == 0, ContinuousClock.now < missed {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(client.missedThumps >= 1)

        // QLab was slow, not dead. The withheld reply now arrives, after the
        // request that asked for it has already given up.
        peer.withholdRepliesTo = []
        peer.releaseWithheldReplies()

        let counted = ContinuousClock.now + .seconds(3)
        while client.lateReplyCount == 0, ContinuousClock.now < counted {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Correlation is by address in FIFO order and QLab's envelope carries
        // no request identifier, so without this the late reply would satisfy
        // whichever request was next in line for `/thump`.
        #expect(client.lateReplyCount >= 1)
    }

    /// Overflow needs a *stalled consumer*, not a fast producer.
    ///
    /// The receive loop only re-arms after handing each packet to the actor,
    /// so inbound traffic paces itself and the buffer stays about one event
    /// deep however hard QLab pushes — a burst of four thousand messages does
    /// not overflow it. What does is the reading side stopping while messages
    /// keep arriving: the main actor held up behind a redraw on a large show.
    /// That is what this reproduces, by never iterating the stream.
    @Test("A consumer that stops reading overflows the buffer and is told what it lost")
    func stalledConsumerOverflowIsReported() async throws {
        let peer = try AuthorizationPeer()
        defer { peer.stop() }
        let port = try await peer.start()

        let connection = QLabConnection(endpoint: QLabServer.localhost(port: port).endpoint)
        let losses = EventLossRecorder()
        await connection.setEventsDroppedHandler { count in
            await losses.record(count)
        }

        let stream = await connection.start()
        try await connection.waitUntilReady(timeout: 5)

        // A consumer that reads one event and then stops — and one that keeps
        // hold of the stream while it does. Simply discarding the stream would
        // *terminate* it, and a terminated stream reports `.terminated`
        // rather than dropping anything, so it would prove nothing.
        let stalledReader = Task {
            for await _ in stream {
                try? await Task.sleep(for: .seconds(30))
            }
        }
        defer { stalledReader.cancel() }

        // The peer registers accepted connections on a hop of its own, so
        // pushing the instant our socket is ready broadcasts to nobody.
        let accepted = ContinuousClock.now + .seconds(5)
        while peer.connectionCount == 0, ContinuousClock.now < accepted {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(peer.connectionCount > 0)

        peer.pushBurst(
            OSCMessage("/update/workspace/W/cue_id/C1"),
            count: QLabConnection.eventBufferCapacity * 4
        )

        let deadline = ContinuousClock.now + .seconds(10)
        while await losses.total == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await connection.cancel()

        // `yield`'s result was discarded before, so this was completely
        // silent — and the comment on the buffer claimed it could not happen.
        #expect(await losses.total > 0)
        // Coalesced into episodes rather than one report per lost event.
        // Without the reporting window this was one call per drop — over a
        // thousand of them for this burst, each asking the client to recover
        // from the same episode again.
        let reports = await losses.reportCount
        let lost = await losses.total
        #expect(reports <= 25)
        #expect(reports < lost)
    }

    /// Connection-action availability, driven by real session states.
    ///
    /// The Connection menu, the sidebar and the connection inspector all read
    /// `canDisconnect` / `canConnect` / `canRefresh` and nothing else, so this
    /// is what "every control agrees" means in practice. They previously
    /// applied three different conditions.
    @Test("Every connection action agrees with itself across session states")
    func connectionActionAvailability() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.requestTimeout = 0.4
        let model = AppModel(preferences: preferences)
        defer { model.disconnect() }
        let server = model.browser.addManualServer(host: "127.0.0.1", port: port)
        let target = WorkspaceSelection(serverID: server.id, workspaceID: "W")

        await model.connect(to: target)
        try #require(model.client.status == .connected)
        #expect(model.canDisconnect)
        #expect(model.canRefresh)

        // Dropped, and now backing off. No live data — which is what the menu
        // used to test — so Disconnect was greyed out for the whole backoff,
        // the one stretch in which an operator most wants it, while the
        // sidebar went on offering it.
        peer.stop()
        let dropped = ContinuousClock.now + .seconds(3)
        while model.client.status.hasLiveData, ContinuousClock.now < dropped {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!model.client.status.hasLiveData)
        try #require(model.client.isSessionActive)

        #expect(model.canDisconnect)
        // Both stay available through a backoff: waiting out a thirty-second
        // timer is the opposite of what someone reaching for these wants.
        #expect(model.canConnect)
        #expect(model.canRefresh)
    }

    @Test("Refresh and Connect stand down while a connection is being set up")
    func availabilityDuringConnectionSetup() async throws {
        // A peer that accepts the socket and never answers holds the client in
        // `connecting` for the whole request timeout, which is the window to
        // observe.
        let peer = try AuthorizationPeer()
        peer.isMute = true
        defer { peer.stop() }
        let port = try await peer.start()

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.requestTimeout = 2
        let model = AppModel(preferences: preferences)
        defer { model.disconnect() }
        let server = model.browser.addManualServer(host: "127.0.0.1", port: port)

        let attempt = Task {
            await model.connect(
                to: WorkspaceSelection(serverID: server.id, workspaceID: "W")
            )
        }
        defer { attempt.cancel() }

        let setup = ContinuousClock.now + .seconds(3)
        while !model.client.status.isTransitional, ContinuousClock.now < setup {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.client.status == .connecting)

        // Refresh rebuilds the session as well as re-asking the network, so
        // running it here would tear down the attempt it was racing. The menu
        // permitted exactly that; the sidebar's button did not.
        #expect(!model.canRefresh)
        #expect(!model.canConnect)
        // Mid-connect is still a session Cuety is holding, so calling it off
        // has to be possible.
        #expect(model.canDisconnect)
    }

    @Test("Disconnecting says goodbye to QLab, and the log shows it")
    func disconnectIsSentAndLogged() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let log = ActivityLog()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        let sentBefore = log.bytesSent
        client.disconnect()

        // The goodbye is best-effort and not awaited, so teardown cannot be
        // blocked by a wedged socket — which means waiting for it here.
        let deadline = ContinuousClock.now + .seconds(3)
        while !log.entries.contains(where: { $0.address == "/disconnect" }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        // These three used to call `connection.send` directly, bypassing the
        // only place outbound traffic is recorded. They were sent and QLab
        // acted on them, but the Activity Log — which presents itself as every
        // message sent and received — showed nothing, and the inspector's
        // sent-bytes total was short by exactly these packets.
        let outbound = log.entries.filter { $0.direction == .outbound }.map(\.address)
        #expect(outbound.contains("/forgetMeNot"))
        #expect(outbound.contains("/udpKeepAlive"))
        #expect(outbound.contains("/disconnect"))
        #expect(log.bytesSent > sentBefore)
    }

    @Test("A dropped session says nothing on the way out")
    func lostSessionSendsNoGoodbye() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        let port = try await peer.start()
        let log = ActivityLog()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 0.3), log: log
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        peer.stop()
        let dropped = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < dropped {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!client.status.hasLiveData)

        // Down a socket that is already gone these can only fail, and logging
        // three failures per drop would describe Cuety's own teardown rather
        // than anything that happened to the show.
        #expect(!log.entries.contains { $0.address == "/disconnect" })
    }

    /// Cue data that changed in QLab while Cuety was not listening — which is
    /// exactly what a dropped update means — is recovered by refetching.
    @Test("A first event loss resynchronizes the cue data")
    func firstEventLossRefetchesCueData() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = [
            .init(
                id: "L1",
                name: "Main",
                cues: [.init(id: "C1", number: "1", name: "House to Half")],
                playheadCueID: "C1"
            ),
        ]
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)
        try #require(client.cueLists.first?.children.count == 1)

        // The show gains a cue, and QLab's notification is the event that got
        // dropped. Cuety cannot know what it missed — only that it missed
        // something.
        peer.cueLists = [
            .init(
                id: "L1",
                name: "Main",
                cues: [
                    .init(id: "C1", number: "1", name: "House to Half"),
                    .init(id: "C2", number: "2", name: "Thunder Crash"),
                ],
                playheadCueID: "C1"
            ),
        ]

        client.handleEventLoss(1)

        // Asserting the *effect*, not that a method was called: the second cue
        // can only appear here if the cue tree was genuinely refetched.
        let deadline = ContinuousClock.now + .seconds(5)
        while client.cueLists.first?.children.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.cueLists.first?.children.count == 2)
        #expect(client.droppedEventCount == 1)
        // Resynchronizing keeps the session; it does not rebuild it.
        #expect(client.status == .connected)
    }

    @Test("A second event loss inside the window rebuilds the session")
    func repeatEventLossRebuildsTheSession() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let log = ActivityLog()
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        func cueListRequests() -> Int {
            log.entries.filter {
                $0.direction == .outbound && $0.address.hasSuffix("/cueLists")
            }.count
        }
        let handshakeRequests = cueListRequests()

        // First loss: resynchronize. Let it finish, or the second report would
        // simply supersede this recovery instead of escalating past it.
        client.handleEventLoss(1)
        let resynced = ContinuousClock.now + .seconds(5)
        while cueListRequests() == handshakeRequests, ContinuousClock.now < resynced {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(cueListRequests() > handshakeRequests)

        // Second loss, well inside the escalation window: refetching did not
        // hold, which is what a lapsed subscription looks like, so the socket
        // and both subscriptions get rebuilt.
        let socketsBefore = peer.connectionCount
        client.handleEventLoss(1)

        // A new socket on the peer is the observable proof of a rebuild — a
        // refetch reuses the one it has.
        let rebuilt = ContinuousClock.now + .seconds(5)
        while peer.connectionCount == socketsBefore, ContinuousClock.now < rebuilt {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(peer.connectionCount > socketsBefore)

        let settled = ContinuousClock.now + .seconds(5)
        while client.status != .connected, ContinuousClock.now < settled {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.status == .connected)
        #expect(client.isSubscribedToUpdates)
        #expect(client.currentPlayheadCueID == "C1")
    }

    /// A show whose standing-by cue has detail values, so the pills have
    /// something to lose.
    private static func showWithDetails(
        duration: Double, notes: String
    ) -> [AuthorizationPeer.CueListStub] {
        [
            .init(
                id: "L1",
                name: "Main",
                cues: [
                    .init(
                        id: "C1",
                        number: "1",
                        name: "House to Half",
                        duration: duration,
                        notes: notes
                    ),
                ],
                playheadCueID: "C1"
            ),
        ]
    }

    @Test("Editing a cue does not leave the detail pills blank")
    func cueEditKeepsDetailPillsPopulated() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.showWithDetails(duration: 4.25, notes: "Hold for the door")
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        // The pills are populated, which is the state that used to be lost.
        try #require(client.playheadCue?.duration == 4.25)
        try #require(client.playheadCue?.notes == "Hold for the door")

        // The operator edits the cue in QLab. QLab reports the edit as a
        // `cue_id` update and Cuety refetches the tree — and `/cueLists`
        // carries none of these values, so a refetch that stopped there
        // replaced a populated cue with a bare one.
        peer.cueLists = Self.showWithDetails(duration: 9.5, notes: "Hold for the slam")
        peer.push(OSCMessage("/update/workspace/W/cue_id/C1"))

        let deadline = ContinuousClock.now + .seconds(5)
        while client.playheadCue?.duration != 9.5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        // Repopulated, and with the *new* values rather than the carried-over
        // old ones: carrying forward only avoids the blank flicker, the
        // refetch is what makes them true.
        #expect(client.playheadCue?.duration == 9.5)
        #expect(client.playheadCue?.notes == "Hold for the slam")
    }

    @Test("An unrelated cue edit never blanks the pills, even for an instant")
    func cueEditDoesNotFlickerThePills() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.showWithDetails(duration: 4.25, notes: "Hold for the door")
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.playheadCue?.duration == 4.25)

        // Watch the value across the whole refetch. An edit elsewhere in the
        // workspace refetches the entire tree, and on a stage display the
        // pills dropping out for a round trip is a visible flicker caused by
        // something that had nothing to do with the cue being shown.
        let blanked = Task { @MainActor in
            var sawBlank = false
            for _ in 0..<200 {
                if client.playheadCue?.duration == nil { sawBlank = true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return sawBlank
        }

        peer.push(OSCMessage("/update/workspace/W/cue_id/C1"))
        #expect(await blanked.value == false)
        #expect(client.playheadCue?.duration == 4.25)
    }

    @Test("Reconnecting keeps the cue list the operator was watching")
    func reconnectKeepsWatchedCueList() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = [.init(id: "L1", name: "Main"), .init(id: "L2", name: "Effects")]
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)
        try #require(client.watchedCueListID == "L1")

        client.watchedCueListID = "L2"
        await client.reconnect()

        #expect(client.status == .connected)
        // Teardown clears the watched list and the handshake falls back to the
        // first one, so without a remembered preference a drop mid-show would
        // silently move the display back to "Main".
        #expect(client.watchedCueListID == "L2")
    }
}

/// Collects what the connection reports losing to buffer overflow.
private actor EventLossRecorder {
    private(set) var total = 0
    private(set) var reportCount = 0

    func record(_ count: Int) {
        total += count
        reportCount += 1
    }
}

/// A local OSC peer supplies real TCP replies without modifying a QLab show.
@MainActor
private final class AuthorizationPeer {
    struct CueListStub {
        let id: String
        let name: String
        var cues: [CueStub] = []
        /// What `playbackPositionID` answers for this list. `nil` is QLab's
        /// `"none"` — a list with an unset playhead.
        var playheadCueID: String?
    }

    struct CueStub {
        let id: String
        let number: String
        let name: String
        /// What `valuesForKeys` answers for this cue.
        ///
        /// Deliberately separate from the fields above: `/cueLists` does not
        /// report duration, waits, notes or continue mode, and a peer that
        /// served them together could not reproduce the detail pills blanking
        /// after a cue edit.
        var duration: Double?
        var notes: String?
    }

    private let listener: NWListener
    private var connections: [NWConnection] = []
    var denyHeartbeat = false
    var denyCueLists = false

    /// What `/workspaces` reports. Emptying it is how a test closes a
    /// workspace out from under the client.
    var openWorkspaceIDs = ["W"]

    /// What `/cueLists` reports.
    var cueLists: [CueListStub] = []

    /// Answer nothing at all, while leaving the socket up: a QLab that is
    /// still running and has stopped talking.
    var isMute = false

    /// Address suffixes whose replies are queued instead of sent, until
    /// ``releaseWithheldReplies()`` lets them go.
    ///
    /// A QLab that is slow rather than silent, which is the case that matters:
    /// a reply held past its request's timeout and then delivered is exactly
    /// the late reply that must not be given to a later request.
    var withholdRepliesTo: Set<String> = []

    private var withheldReplies: [(connection: NWConnection, packet: Data)] = []

    /// Sends everything held back so far, all at once.
    func releaseWithheldReplies() {
        let queued = withheldReplies
        withheldReplies.removeAll()
        for held in queued {
            held.connection.send(content: held.packet, completion: .contentProcessed { _ in })
        }
    }

    init() throws { listener = try NWListener(using: .qlabTCP(), on: .any) }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { [weak self] state in
                    if case .ready = state {
                        Task { @MainActor in self?.receive(connection) }
                    }
                }
                connection.start(queue: .main)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(returning: self.listener.port!.rawValue)
                    case .failed(let error):
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    /// Sends an unsolicited message, the way QLab pushes workspace updates.
    func push(_ message: OSCMessage) {
        let packet = OSCEncoder().encode(message)
        for connection in connections {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// How many clients the peer has accepted.
    ///
    /// Registration happens on a hop from the listener's callback, so a test
    /// that pushes as soon as its own socket is ready can beat the peer to it
    /// and broadcast to nobody.
    var connectionCount: Int { connections.count }

    /// Pushes the same message `count` times as fast as the socket takes it —
    /// a group cue firing far more updates than a display can read.
    func pushBurst(_ message: OSCMessage, count: Int) {
        let packet = OSCEncoder().encode(message)
        for connection in connections {
            for _ in 0..<count {
                connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    /// The status and `data` payload to answer an address with, or `nil` to
    /// say nothing at all.
    private func reply(to address: String) -> (status: String, payload: Any)? {
        guard !isMute else { return nil }

        if address == "/workspaces" {
            return ("ok", openWorkspaceIDs.map {
                ["uniqueID": $0, "displayName": "Test"]
            })
        }

        // Workspace methods arrive as ["", "workspace", <id>, …].
        let components = address.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 3, components[1] == "workspace" else {
            return ("ok", NSNull())
        }

        let method = components.dropFirst(3).joined(separator: "/")

        switch method {
        case "connect":
            return ("ok", "ok:view")
        case "cueLists":
            guard !denyCueLists else { return ("denied", "denied") }
            return ("ok", cueLists.map { list in
                [
                    "uniqueID": list.id,
                    "name": list.name,
                    "cues": list.cues.map {
                        ["uniqueID": $0.id, "number": $0.number, "name": $0.name]
                            as [String: Any]
                    },
                ] as [String: Any]
            })
        case "thump":
            return (denyHeartbeat ? "denied" : "ok", "thump")
        default:
            let parts = method.split(separator: "/")
            guard parts.count == 3, parts[0] == "cue_id" else {
                return ("ok", NSNull())
            }

            // `/workspace/<id>/cue_id/<listID>/playbackPositionID`, which is
            // what puts a cue on the display: without it a populated show
            // still has nothing standing by.
            if parts[2] == "playbackPositionID" {
                let list = cueLists.first { $0.id == String(parts[1]) }
                return ("ok", list?.playheadCueID ?? "none")
            }

            // `…/cue_id/<cueID>/valuesForKeys`, which is the *only* place the
            // detail pills' values come from — `/cueLists` never carries them.
            if parts[2] == "valuesForKeys" {
                let cueID = String(parts[1])
                let cue = cueLists.lazy.flatMap(\.cues).first { $0.id == cueID }
                var values: [String: Any] = [:]
                if let duration = cue?.duration { values["duration"] = duration }
                if let notes = cue?.notes { values["notes"] = notes }
                return ("ok", values)
            }

            return ("ok", NSNull())
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, error == nil, let data else { return }
                if case .message(let message) = try? OSCDecoder().decode(data),
                   let reply = self.reply(to: message.address),
                   let json = try? JSONSerialization.data(withJSONObject: [
                       "address": message.address,
                       "status": reply.status,
                       "data": reply.payload,
                   ]) {
                    let outgoing = OSCMessage(
                        "/reply" + message.address,
                        [.string(String(decoding: json, as: UTF8.self))]
                    )
                    let packet = OSCEncoder().encode(outgoing)

                    if self.withholdRepliesTo.contains(where: message.address.hasSuffix) {
                        self.withheldReplies.append((connection, packet))
                    } else {
                        connection.send(
                            content: packet,
                            completion: .contentProcessed { _ in }
                        )
                    }
                }
                self.receive(connection)
            }
        }
    }
}
