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

/// A local OSC peer supplies real TCP replies without modifying a QLab show.
@MainActor
private final class AuthorizationPeer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    var denyHeartbeat = false
    var denyCueLists = false

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
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil, let data else { return }
                if case .message(let message) = try? OSCDecoder().decode(data) {
                    let address = message.address
                    var status = "ok"
                    var payload: Any = NSNull()
                    switch address {
                    case "/workspaces": payload = [["uniqueID": "W", "displayName": "Test"]]
                    case "/workspace/W/connect": payload = "ok:view"
                    case "/workspace/W/cueLists":
                        status = self.denyCueLists ? "denied" : "ok"
                        payload = self.denyCueLists ? "denied" : [] as [String]
                    case "/workspace/W/thump":
                        status = self.denyHeartbeat ? "denied" : "ok"
                        payload = "thump"
                    default: break
                    }
                    if let json = try? JSONSerialization.data(withJSONObject: [
                        "address": address, "status": status, "data": payload,
                    ]) {
                        let reply = OSCMessage("/reply" + address, [.string(String(decoding: json, as: UTF8.self))])
                        connection.send(content: OSCEncoder().encode(reply), completion: .contentProcessed { _ in })
                    }
                }
                self.receive(connection)
            }
        }
    }
}
