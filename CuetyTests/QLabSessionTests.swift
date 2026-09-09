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

    @Test("A QLab that quits leaves a session that is visibly retrying")
    func quitPeerLeavesSessionRetrying() async throws {
        let peer = try AuthorizationPeer()
        let port = try await peer.start()
        let client = QLabClient(
            preferences: try makePreferences(requestTimeout: 0.3), log: ActivityLog()
        )
        defer { client.disconnect() }
        await client.connect(to: .localhost(port: port), workspaceID: "W", passcode: nil)
        try #require(client.status == .connected)

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

/// A local OSC peer supplies real TCP replies without modifying a QLab show.
@MainActor
private final class AuthorizationPeer {
    struct CueListStub {
        let id: String
        let name: String
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

        switch components.dropFirst(3).joined(separator: "/") {
        case "connect":
            return ("ok", "ok:view")
        case "cueLists":
            guard !denyCueLists else { return ("denied", "denied") }
            return ("ok", cueLists.map {
                ["uniqueID": $0.id, "name": $0.name, "cues": [Any]()] as [String: Any]
            })
        case "thump":
            return (denyHeartbeat ? "denied" : "ok", "thump")
        default:
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
                    connection.send(
                        content: OSCEncoder().encode(outgoing),
                        completion: .contentProcessed { _ in }
                    )
                }
                self.receive(connection)
            }
        }
    }
}
