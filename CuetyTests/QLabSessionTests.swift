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
    func deniedHeartbeat() async throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompted = false
        client.onPasscodeRequired = { _ in prompted = true }
        await #expect(throws: QLabClient.RequestFailure.self) {
            _ = try await client.validateSessionReply(
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
    func deniedCueLists() async throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompted = false
        client.onPasscodeRequired = { _ in prompted = true }
        await #expect(throws: QLabClient.RequestFailure.self) {
            _ = try await client.validateSessionReply(
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
    func repeatedDenialsPromptOnce() async throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        var prompts = 0
        client.onPasscodeRequired = { _ in prompts += 1 }
        for _ in 0..<3 {
            await #expect(throws: QLabClient.RequestFailure.self) {
                _ = try await client.validateSessionReply(
                    message("/workspace/W/thump", status: "denied", data: "\"thump\""),
                    as: String.self
                )
            }
        }
        #expect(prompts == 1)
    }

    @Test("Failed setup requests cannot masquerade as successful empty replies",
          arguments: ["/updates", "/listen/playhead", "/workspace/W/cueLists"])
    func failedSetup(address: String) async {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        await #expect(throws: QLabClient.RequestFailure.self) {
            _ = try await client.validateSessionReply(
                message(address, status: "error", data: "null"), as: QLabEmptyPayload.self
            )
        }
    }

    @Test("An authorized empty cue list remains valid")
    func emptyCueLists() async throws {
        let client = QLabClient(preferences: Preferences(), log: ActivityLog())
        let reply = try await client.validateSessionReply(
            message("/workspace/W/cueLists", status: "ok", data: "[]"), as: [Cue].self
        )
        #expect(reply.data?.isEmpty == true)
        #expect(client.status == .offline)
    }

    @Test("Cancelling a connection releases an event-loss handler cycle")
    func cancellingConnectionReleasesEventLossHandler() async {
        var connection: QLabConnection? = QLabConnection(endpoint: QLabServer.localhost().endpoint)
        weak let weakConnection = connection

        await connection?.setEventsDroppedHandler { [connection] _ in
            _ = connection
        }
        await connection?.cancel()
        connection = nil

        #expect(weakConnection == nil)
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
        #expect(started.duration(to: .now) < .seconds(3))
    }

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
        #expect(client.isSessionActive)

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
        try #require(client.playheadCue?.uniqueID == "C1")

        peer.stop()

        let deadline = ContinuousClock.now + .seconds(3)
        while client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

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

    @Test("A drop takes the cue number off the Dock badge")
    func dropClearsTheDockBadge() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        let port = try await peer.start()
        let model = AppModel(preferences: try makePreferences(requestTimeout: 0.3))
        defer { model.disconnect() }
        model.preferences.showsDockBadge = true

        await model.client.connect(
            to: .localhost(port: port), workspaceID: "W", passcode: nil
        )
        try #require(model.client.status == .connected)
        try #require(model.dockBadgeLabel == "1")

        peer.stop()

        let deadline = ContinuousClock.now + .seconds(3)
        while model.client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!model.client.status.hasLiveData)
        #expect(model.standbyCue == nil)
        #expect(model.dockBadgeLabel == nil)
    }

    @Test("A reconnect repopulates the display without a manual refresh")
    func reconnectRepopulatesCueData() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let log = ActivityLog()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.playheadCue?.uniqueID == "C1")

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
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 5), log: ActivityLog()
        )
        defer { client.disconnect() }

        let started = ContinuousClock.now
        let probe = Task { try await client.fetchWorkspaces(from: .localhost(port: port)) }
        try await Task.sleep(for: .milliseconds(100))
        probe.cancel()

        await #expect(throws: CancellationError.self) { _ = try await probe.value }
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

        peer.withholdRepliesTo = ["cueLists"]

        let started = ContinuousClock.now
        let refresh = Task { try await client.refreshCueLists() }
        try await Task.sleep(for: .milliseconds(100))
        refresh.cancel()

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

        peer.withholdRepliesTo = ["thump"]

        let missed = ContinuousClock.now + .seconds(3)
        while client.missedThumps == 0, ContinuousClock.now < missed {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(client.missedThumps >= 1)

        peer.withholdRepliesTo = []
        peer.releaseWithheldReplies()

        let counted = ContinuousClock.now + .seconds(3)
        while client.lateReplyCount == 0, ContinuousClock.now < counted {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.lateReplyCount >= 1)
    }

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

        let stalledReader = Task {
            for await _ in stream {
                try? await Task.sleep(for: .seconds(30))
            }
        }
        defer { stalledReader.cancel() }

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

        #expect(await losses.total > 0)
        let reports = await losses.reportCount
        let lost = await losses.total
        #expect(reports <= 25)
        #expect(reports < lost)
    }

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

        peer.stop()
        let dropped = ContinuousClock.now + .seconds(3)
        while model.client.status.hasLiveData, ContinuousClock.now < dropped {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!model.client.status.hasLiveData)
        try #require(model.client.isSessionActive)

        #expect(model.canDisconnect)
        #expect(model.canConnect)
        #expect(model.canRefresh)
    }

    @Test("Refresh and Connect stand down while a connection is being set up")
    func availabilityDuringConnectionSetup() async throws {
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

        #expect(!model.canRefresh)
        #expect(!model.canConnect)
        #expect(model.canDisconnect)
    }

    @Test("A transport loss keeps the selected target available for reconnect")
    func transportLossKeepsModelSelectionForReconnect() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        let port = try await peer.start()
        defer { peer.stop() }

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.requestTimeout = 0.3
        let model = AppModel(preferences: preferences)
        defer { model.disconnect() }

        let server = model.browser.addManualServer(host: "127.0.0.1", port: port)
        let target = WorkspaceSelection(serverID: server.id, workspaceID: "W")
        await model.connect(to: target)

        try #require(model.client.status == .connected)
        try #require(model.selection == target)

        peer.stop()

        let deadline = ContinuousClock.now + .seconds(3)
        while model.client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.client.status.hasLiveData == false)
        #expect(model.client.isSessionActive)
        #expect(model.selection == target)

        model.disconnect()

        #expect(model.client.status == .offline)
        #expect(!model.client.isSessionActive)
        #expect(model.selection == nil)
    }

    @Test("Closing the workspace clears both client and model session state")
    func workspaceClosureClearsModelSelection() async throws {
        let peer = try AuthorizationPeer()
        let port = try await peer.start()
        defer { peer.stop() }

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        let model = AppModel(preferences: preferences)
        defer { model.disconnect() }

        let server = model.browser.addManualServer(host: "127.0.0.1", port: port)
        let target = WorkspaceSelection(serverID: server.id, workspaceID: "W")
        await model.connect(to: target)
        try #require(model.client.status == .connected)

        peer.push(OSCMessage("/update/workspace/W/disconnect"))

        let deadline = ContinuousClock.now + .seconds(3)
        while model.client.status.hasLiveData, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.client.status == .workspaceClosed)
        #expect(!model.client.isSessionActive)
        #expect(model.selection == nil)
        #expect(preferences.lastWorkspace == nil)
    }

    @Test("A rejected passcode keeps the model selection for the retry prompt")
    func rejectedPasscodeKeepsModelSelection() async throws {
        let peer = try AuthorizationPeer()
        peer.denyCueLists = true
        let port = try await peer.start()
        defer { peer.stop() }

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        let model = AppModel(preferences: preferences)
        defer { model.disconnect() }

        let server = model.browser.addManualServer(host: "127.0.0.1", port: port)
        let target = WorkspaceSelection(serverID: server.id, workspaceID: "W")
        await model.connect(to: target, useSavedPasscode: false)

        #expect(model.client.status == .needsPasscode(rejected: false))
        #expect(!model.client.isSessionActive)
        #expect(model.selection == target)
        #expect(model.passcodePrompt?.serverID == target.serverID)
        #expect(model.passcodePrompt?.workspaceID == target.workspaceID)
        #expect(model.passcodePrompt?.wasRejected == false)
    }

    @Test("Disconnecting says goodbye to QLab, and the log shows it")
    func disconnectIsSentAndLogged() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let port = try await peer.start()
        let log = ActivityLog()
        log.addViewer()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        let sentBefore = log.bytesSent
        client.disconnect()

        let deadline = ContinuousClock.now + .seconds(3)
        while !log.entries.contains(where: { $0.address == "/disconnect" }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

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
        log.addViewer()
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

        #expect(!log.entries.contains { $0.address == "/disconnect" })
    }

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

        let deadline = ContinuousClock.now + .seconds(5)
        while client.cueLists.first?.children.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.cueLists.first?.children.count == 2)
        #expect(client.droppedEventCount == 1)
        #expect(client.status == .connected)
    }

    @Test("A second event loss inside the window rebuilds the session")
    func repeatEventLossRebuildsTheSession() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let log = ActivityLog()
        log.addViewer()
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

        client.handleEventLoss(1)
        let resynced = ContinuousClock.now + .seconds(5)
        while cueListRequests() == handshakeRequests, ContinuousClock.now < resynced {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(cueListRequests() > handshakeRequests)

        let socketsBefore = peer.connectionCount
        client.handleEventLoss(1)

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
        let log = ActivityLog()
        log.addViewer()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        try #require(client.playheadCue?.duration == 4.25)
        try #require(client.playheadCue?.notes == "Hold for the door")

        func cueListRequests() -> Int {
            log.entries.filter {
                $0.direction == .outbound && $0.address.hasSuffix("/cueLists")
            }.count
        }
        let snapshotRequests = cueListRequests()

        peer.cueLists = Self.showWithDetails(duration: 9.5, notes: "Hold for the slam")
        peer.push(OSCMessage("/update/workspace/W/cue_id/C1"))

        let deadline = ContinuousClock.now + .seconds(5)
        while client.playheadCue?.duration != 9.5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(client.playheadCue?.duration == 9.5)
        #expect(client.playheadCue?.notes == "Hold for the slam")
        #expect(cueListRequests() == snapshotRequests)
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

    @Test("A playhead move via /updates fetches details without stalling")
    func playheadUpdateDoesNotStallTheEventLoop() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = [
            .init(
                id: "L1",
                name: "Main",
                cues: [
                    .init(id: "C1", number: "1", name: "House", duration: 1),
                    .init(id: "C2", number: "2", name: "Thunder", duration: 42),
                ],
                playheadCueID: "C1"
            ),
        ]
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 5), log: ActivityLog()
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.playheadCue?.duration == 1)

        peer.push(OSCMessage("/update/workspace/W/cueList/L1/playbackPosition", [.string("C2")]))

        let deadline = ContinuousClock.now + .seconds(2)
        while client.playheadCue?.duration != 42, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(client.currentPlayheadCueID == "C2")
        #expect(client.playheadCue?.duration == 42)
        #expect(client.status.hasLiveData)
    }

    @Test("A run of playhead moves collapses into one details request")
    func rapidPlayheadMovesAreCoalesced() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = [
            .init(
                id: "L1",
                name: "Main",
                cues: (1...8).map {
                    .init(id: "C\($0)", number: "\($0)", name: "Cue \($0)", duration: Double($0))
                },
                playheadCueID: "C1"
            ),
        ]
        defer { peer.stop() }
        let log = ActivityLog()
        log.addViewer()
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)

        func detailRequests() -> Int {
            log.entries.filter {
                $0.direction == .outbound && $0.address.hasSuffix("/valuesForKeys")
            }.count
        }
        let handshakeRequests = detailRequests()

        for cue in 2...8 {
            peer.push(
                OSCMessage(
                    "/update/workspace/W/cueList/L1/playbackPosition", [.string("C\(cue)")]
                )
            )
        }

        let deadline = ContinuousClock.now + .seconds(3)
        while client.playheadCue?.duration != 8, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(client.currentPlayheadCueID == "C8")
        #expect(client.playheadCue?.duration == 8)
        #expect(detailRequests() - handshakeRequests < 7)
    }

    @Test("A failed playhead query is unknown, not empty")
    func failedPlayheadQueryIsUnknown() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        peer.failPlaybackPosition = true
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        let state = try #require(client.playheads["L1"])
        #expect(state.isKnown == false)
        #expect(state.cueID == nil)
        if case .unknown = state {} else {
            Issue.record("Expected .unknown, got \(state)")
        }
        #expect(state != .unset)
    }

    @Test("Deleting the watched cue list moves the display to a valid one")
    func deletingWatchedCueListReconciles() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = [
            .init(id: "L1", name: "Main", cues: [.init(id: "C1", number: "1", name: "House")],
                  playheadCueID: "C1"),
            .init(id: "L2", name: "Effects", cues: [.init(id: "C9", number: "9", name: "Rain")],
                  playheadCueID: "C9"),
        ]
        defer { peer.stop() }
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: ActivityLog())
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

        client.watchedCueListID = "L2"
        try #require(client.currentPlayheadCueID == "C9")

        peer.cueLists = [
            .init(id: "L1", name: "Main", cues: [.init(id: "C1", number: "1", name: "House")],
                  playheadCueID: "C1"),
        ]
        peer.push(OSCMessage("/update/workspace/W"))

        let deadline = ContinuousClock.now + .seconds(5)
        while client.watchedCueListID == "L2", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(client.watchedCueListID == "L1")
        #expect(client.currentPlayheadCueID == "C1")
        #expect(client.playheads["L2"] == nil)
    }

    @Test("A broadcast for an unknown cue refetches instead of guessing a list")
    func broadcastForUnknownCueDoesNotGuess() async throws {
        let peer = try AuthorizationPeer()
        peer.cueLists = Self.populatedShow
        defer { peer.stop() }
        let log = ActivityLog()
        log.addViewer()
        let port = try await peer.start()
        let client = QLabClient(preferences: try makePreferences(), log: log)
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.watchedCueListID == "L1")
        try #require(client.currentPlayheadCueID == "C1")

        func cueListRequests() -> Int {
            log.entries.filter {
                $0.direction == .outbound && $0.address.hasSuffix("/cueLists")
            }.count
        }
        let before = cueListRequests()

        peer.push(
            OSCMessage(
                "/qlab/event/workspace/playhead",
                [.string("99"), .string("Newly Added"), .string("C-NEW"), .string("Audio")]
            )
        )

        let deadline = ContinuousClock.now + .seconds(5)
        while cueListRequests() == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(cueListRequests() > before)
        #expect(client.playheads["L1"]?.cueID != "C-NEW")
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
        #expect(client.watchedCueListID == "L2")
    }
}

private actor EventLossRecorder {
    private(set) var total = 0
    private(set) var reportCount = 0

    func record(_ count: Int) {
        total += count
        reportCount += 1
    }
}

@MainActor
private final class AuthorizationPeer {
    struct CueListStub {
        let id: String
        let name: String
        var cues: [CueStub] = []
        var playheadCueID: String?
    }

    struct CueStub {
        let id: String
        let number: String
        let name: String
        var duration: Double?
        var notes: String?
    }

    private let listener: NWListener
    private var connections: [NWConnection] = []
    var denyHeartbeat = false
    var denyCueLists = false

    var failPlaybackPosition = false

    var openWorkspaceIDs = ["W"]

    var cueLists: [CueListStub] = []

    var isMute = false

    var withholdRepliesTo: Set<String> = []

    private var withheldReplies: [(connection: NWConnection, packet: Data)] = []

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

    func push(_ message: OSCMessage) {
        let packet = OSCEncoder().encode(message)
        for connection in connections {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    var connectionCount: Int { connections.count }

    func pushBurst(_ message: OSCMessage, count: Int) {
        let packet = OSCEncoder().encode(message)
        for connection in connections {
            for _ in 0..<count {
                connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    private func reply(to address: String) -> (status: String, payload: Any)? {
        guard !isMute else { return nil }

        if address == "/workspaces" {
            return ("ok", openWorkspaceIDs.map {
                ["uniqueID": $0, "displayName": "Test"]
            })
        }

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

            if parts[2] == "playbackPositionID" {
                guard !failPlaybackPosition else { return ("error", NSNull()) }
                let list = cueLists.first { $0.id == String(parts[1]) }
                return ("ok", list?.playheadCueID ?? "none")
            }

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
