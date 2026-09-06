import Foundation
import Network
import os

/// Drives a QLab session: handshake, subscriptions, request/reply correlation,
/// heartbeat, and reconnection.
///
/// `@MainActor` and `@Observable`, so views read its properties directly. All
/// socket work happens inside ``QLabConnection``; this type only orchestrates.
@Observable
@MainActor
final class QLabClient {
    private let logger = Logger(subsystem: "com.caseyburnham.Cuety", category: "QLabClient")
    private let preferences: Preferences
    private let log: ActivityLog

    // MARK: Observable state

    private(set) var status: ConnectionStatus = .offline

    /// The workspace we're connected to, once the handshake completes.
    private(set) var workspace: QLabWorkspaceInfo?

    /// QLab's reported version, from `/workspaces`.
    private(set) var qlabVersion: String?

    /// Cue lists as last fetched. Each element is a cue list; its `children`
    /// are the cues within.
    private(set) var cueLists: [Cue] = []

    /// Playhead per cue list ID. A missing entry means the playhead is unset
    /// for that list, which is distinct from "we haven't asked yet".
    private(set) var playheads: [String: String] = [:]

    /// Which cue list the display is following.
    var watchedCueListID: String?

    // MARK: Session facts, for the inspector

    private(set) var connectedSince: Date?
    private(set) var usedPasscode = false
    private(set) var isSubscribedToUpdates = false
    private(set) var reconnectCount = 0
    private(set) var lastErrorDescription: String?
    private(set) var lastErrorDate: Date?

    // MARK: Heartbeat

    private(set) var heartbeatCount = 0
    private(set) var lastThumpDate: Date?
    private(set) var lastRoundTrip: TimeInterval?
    private(set) var meanRoundTrip: TimeInterval?
    private(set) var missedThumps = 0
    private var roundTripSamples: [TimeInterval] = []

    // MARK: Private plumbing

    private var connection: QLabConnection?
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var pending: [UUID: PendingRequest] = [:]
    private var pendingByAddress: [String: [UUID]] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// The server and workspace to reconnect to after a drop.
    private var currentTarget: (server: QLabServer, workspaceID: String, passcode: String?)?

    /// Successive failures, for exponential backoff.
    private var backoffAttempt = 0

    init(preferences: Preferences, log: ActivityLog) {
        self.preferences = preferences
        self.log = log
    }

    // MARK: - Connecting

    /// Queries a server for its workspaces without committing to one.
    ///
    /// This is a short-lived connection: the sidebar needs workspace names
    /// before the user has chosen anything.
    func fetchWorkspaces(from server: QLabServer) async throws -> [QLabWorkspaceInfo] {
        let probe = QLabConnection(endpoint: server.endpoint)
        defer { Task { await probe.cancel() } }

        let stream = await probe.start()
        try await waitForReady(on: stream)

        let reply = try await request(
            OSCMessage("/workspaces"),
            as: [QLabWorkspaceInfo].self,
            over: probe,
            stream: stream
        )
        return reply.data ?? []
    }

    /// Connects to a workspace and completes the full handshake.
    func connect(to server: QLabServer, workspaceID: String, passcode: String?) async {
        disconnect(sendDisconnect: false)

        currentTarget = (server, workspaceID, passcode)
        status = .connecting

        let connection = QLabConnection(endpoint: server.endpoint)
        self.connection = connection
        let stream = await connection.start()

        // One task consumes the event stream for the whole session.
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }

        do {
            try await performHandshake(workspaceID: workspaceID, passcode: passcode)
        } catch {
            await handleHandshakeFailure(error)
        }
    }

    /// Tears down the session, optionally telling QLab first.
    func disconnect(sendDisconnect: Bool = true) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        let connection = self.connection
        let workspaceID = workspace?.uniqueID

        if sendDisconnect, let connection, let workspaceID {
            // Best effort and deliberately not awaited: QLab is told we're
            // going, but a wedged socket must not block teardown.
            Task {
                try? await connection.send(OSCMessage("/workspace/\(workspaceID)/updates", [.int32(0)]))
                try? await connection.send(OSCMessage("/workspace/\(workspaceID)/disconnect"))
                await connection.cancel()
            }
        } else if let connection {
            Task { await connection.cancel() }
        }

        eventTask?.cancel()
        eventTask = nil
        self.connection = nil

        failAllPendingRequests(with: RequestFailure.disconnected)

        workspace = nil
        isSubscribedToUpdates = false
        connectedSince = nil
        cueLists = []
        playheads = [:]
        watchedCueListID = nil
        resetHeartbeatStatistics()

        if case .failed = status {} else {
            status = .offline
        }
    }

    // MARK: - Handshake

    private func performHandshake(workspaceID: String, passcode: String?) async throws {
        guard let connection else { throw RequestFailure.disconnected }

        // 1. Enumerate workspaces, so we know the display name and version.
        let workspacesReply = try await request(
            OSCMessage("/workspaces"),
            as: [QLabWorkspaceInfo].self
        )
        let workspaces = workspacesReply.data ?? []
        guard let match = workspaces.first(where: { $0.uniqueID == workspaceID }) else {
            throw RequestFailure.workspaceUnavailable(id: workspaceID)
        }
        workspace = match
        qlabVersion = match.version

        // 2. Connect, with the passcode if we have one.
        let connectMessage = passcode.map {
            OSCMessage("/workspace/\(workspaceID)/connect", [.string($0)])
        } ?? OSCMessage("/workspace/\(workspaceID)/connect")

        let connectReply = try await request(connectMessage, as: String.self)
        switch connectReply.data {
        case "ok":
            usedPasscode = passcode != nil
        case "badpass":
            // Never retried automatically: QLab lengthens its own delay after
            // repeated failures, so hammering it makes the situation worse.
            status = .needsPasscode(rejected: true)
            throw RequestFailure.passcodeRejected
        default:
            if connectReply.status == .denied {
                status = .needsPasscode(rejected: passcode != nil)
                throw RequestFailure.passcodeRequired
            }
            throw RequestFailure.handshakeFailed(
                step: "connect",
                detail: connectReply.data ?? "no reply data"
            )
        }

        // 3. Ask QLab to reply to everything. This is what makes correlation
        //    reliable — otherwise commands that produce no natural reply would
        //    leave requests hanging until they time out.
        _ = try? await request(
            OSCMessage("/workspace/\(workspaceID)/alwaysReply", [.int32(1)]),
            as: QLabEmptyPayload.self
        )

        // 4. Subscribe to push updates. This is the playhead feed.
        let updatesReply = try await request(
            OSCMessage("/workspace/\(workspaceID)/updates", [.int32(1)]),
            as: QLabEmptyPayload.self
        )
        isSubscribedToUpdates = updatesReply.status.isSuccess

        // 5. Fetch the cue lists.
        try await refreshCueLists()

        connectedSince = Date()
        backoffAttempt = 0
        status = .connected
        startHeartbeat()

        logger.info("Connected to workspace \(match.displayName, privacy: .public)")
        _ = connection
    }

    private func handleHandshakeFailure(_ error: any Error) async {
        recordError(error)

        switch error {
        case RequestFailure.passcodeRejected, RequestFailure.passcodeRequired:
            // Leave `status` as set by the handshake so the UI can prompt, and
            // do not schedule a reconnect — that would re-trigger the delay.
            break
        default:
            status = .failed(reason: describe(error))
            scheduleReconnect()
        }
    }

    // MARK: - Requests

    private struct PendingRequest {
        let id: UUID
        let address: String
        let continuation: CheckedContinuation<OSCMessage, any Error>
    }

    enum RequestFailure: Error, CustomStringConvertible {
        case disconnected
        case timedOut(address: String)
        case notReady
        case passcodeRequired
        case passcodeRejected
        case workspaceUnavailable(id: String)
        case handshakeFailed(step: String, detail: String)
        case replyUnreadable(String)

        var description: String {
            switch self {
            case .disconnected: "Disconnected from QLab."
            case .timedOut(let address): "QLab did not answer \(address) in time."
            case .notReady: "The connection is not ready."
            case .passcodeRequired: "This workspace needs a passcode."
            case .passcodeRejected: "That passcode was not accepted."
            case .workspaceUnavailable(let id): "Workspace \(id) is no longer open in QLab."
            case .handshakeFailed(let step, let detail): "Handshake failed at \(step): \(detail)"
            case .replyUnreadable(let detail): detail
            }
        }
    }

    /// Sends a message and awaits its typed reply.
    @discardableResult
    private func request<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        guard let connection else { throw RequestFailure.disconnected }
        let replyMessage = try await sendAndAwaitReply(message, over: connection)
        do {
            return try QLabReplyParser.parse(replyMessage, as: payloadType)
        } catch {
            throw RequestFailure.replyUnreadable(String(describing: error))
        }
    }

    /// Variant used by ``fetchWorkspaces(from:)``, which runs against a probe
    /// connection that isn't the session connection.
    private func request<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type,
        over connection: QLabConnection,
        stream: AsyncStream<QLabConnection.Event>
    ) async throws -> QLabReply<Payload> {
        let byteCount = try await connection.send(message)
        log.record(OSCEvent(message: message, direction: .outbound, byteCount: byteCount))

        // A probe has no long-lived event consumer, so read the stream inline
        // until the matching reply shows up or we run out of patience.
        let deadline = Date().addingTimeInterval(preferences.requestTimeout)
        for await event in stream {
            if Date() > deadline { break }
            guard case .received(let incoming, let bytes) = event else { continue }
            log.record(OSCEvent(message: incoming, direction: .inbound, byteCount: bytes))

            guard QLabReplyParser.correlationAddress(of: incoming) == message.address else {
                continue
            }
            do {
                return try QLabReplyParser.parse(incoming, as: payloadType)
            } catch {
                throw RequestFailure.replyUnreadable(String(describing: error))
            }
        }
        throw RequestFailure.timedOut(address: message.address)
    }

    private func sendAndAwaitReply(
        _ message: OSCMessage,
        over connection: QLabConnection
    ) async throws -> OSCMessage {
        let id = UUID()

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(
                id: id, address: message.address, continuation: continuation
            )
            pendingByAddress[message.address, default: []].append(id)

            Task { [weak self] in
                guard let self else { return }
                do {
                    let byteCount = try await connection.send(message)
                    self.log.record(
                        OSCEvent(message: message, direction: .outbound, byteCount: byteCount)
                    )
                } catch {
                    self.fail(requestID: id, with: error)
                    return
                }

                // Every request carries a deadline, so no call site can hang
                // forever waiting on a QLab that has stopped answering.
                self.timeoutTasks[id] = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.preferences.requestTimeout))
                    guard !Task.isCancelled else { return }
                    self.fail(
                        requestID: id,
                        with: RequestFailure.timedOut(address: message.address)
                    )
                }
            }
        }
    }

    private func complete(requestID id: UUID, with message: OSCMessage) {
        guard let request = removePending(id) else { return }
        request.continuation.resume(returning: message)
    }

    private func fail(requestID id: UUID, with error: any Error) {
        guard let request = removePending(id) else { return }
        request.continuation.resume(throwing: error)
    }

    /// Removes a request from both indexes, returning it only the first time —
    /// which is what guarantees a continuation is never resumed twice.
    private func removePending(_ id: UUID) -> PendingRequest? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return nil }
        pendingByAddress[request.address]?.removeAll { $0 == id }
        if pendingByAddress[request.address]?.isEmpty == true {
            pendingByAddress.removeValue(forKey: request.address)
        }
        return request
    }

    private func failAllPendingRequests(with error: any Error) {
        for id in pending.keys {
            fail(requestID: id, with: error)
        }
    }

    /// Waits for a probe connection to reach `.ready`.
    private func waitForReady(on stream: AsyncStream<QLabConnection.Event>) async throws {
        let deadline = Date().addingTimeInterval(preferences.requestTimeout)
        for await event in stream {
            if Date() > deadline { break }
            guard case .stateChanged(let state) = event else { continue }
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw RequestFailure.disconnected
            default: continue
            }
        }
        throw RequestFailure.notReady
    }

    // MARK: - Event handling

    private func handle(_ event: QLabConnection.Event) async {
        switch event {
        case .stateChanged(let state):
            handleStateChange(state)

        case .pathChanged(let isViable):
            if !isViable, status.hasLiveData {
                status = .degraded(reason: "The network path to QLab is temporarily unusable.")
            } else if isViable, case .degraded = status {
                status = .connected
            }

        case .received(let message, let byteCount):
            log.record(OSCEvent(message: message, direction: .inbound, byteCount: byteCount))
            await route(message)

        case .receiveFailed(let error, let byteCount):
            log.record(
                OSCEvent(
                    direction: .malformed,
                    address: "Malformed packet",
                    arguments: error.description,
                    byteCount: byteCount
                )
            )
        }
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .waiting(let error):
            // `.waiting` means the system will retry on its own, so this is a
            // degraded state rather than a failure — don't stack our own
            // backoff on top of the framework's.
            if status.hasLiveData || status == .connecting {
                status = .degraded(reason: "Waiting for the network: \(error.localizedDescription)")
            }

        case .failed(let error):
            recordError(error)
            failAllPendingRequests(with: error)
            status = .failed(reason: error.localizedDescription)
            scheduleReconnect()

        case .cancelled:
            failAllPendingRequests(with: RequestFailure.disconnected)
            if status.hasLiveData {
                status = .failed(reason: "QLab closed the connection.")
                scheduleReconnect()
            }

        default:
            break
        }
    }

    /// Dispatches an incoming message to a pending request or an update handler.
    private func route(_ message: OSCMessage) async {
        // Replies first: match against the oldest in-flight request for the
        // address the reply echoes.
        if QLabReplyParser.isReply(message) {
            if let address = QLabReplyParser.correlationAddress(of: message),
               let id = pendingByAddress[address]?.first {
                complete(requestID: id, with: message)
            }
            return
        }

        // Then push updates.
        if message.address.hasPrefix("/update/") {
            await handleUpdate(message)
        }
    }

    // MARK: - Push updates

    private func handleUpdate(_ message: OSCMessage) async {
        let components = message.addressComponents
        // Shapes, all prefixed by ["update", "workspace", <id>]:
        //   …                                       → reload cue lists
        //   … + ["cue_id", <cueID>]                 → reload one cue
        //   … + ["cueList", <listID>, "playbackPosition"] (+ arg) → playhead moved
        //   … + ["disconnect"]                      → go away
        guard components.count >= 3,
              components[0] == "update",
              components[1] == "workspace"
        else { return }

        let tail = Array(components.dropFirst(3))

        switch tail.first {
        case nil:
            await debouncedCueListRefresh()

        case "disconnect":
            logger.info("QLab asked us to disconnect")
            status = .failed(reason: "QLab closed this workspace.")
            disconnect(sendDisconnect: false)

        case "cue_id":
            if tail.count >= 2 {
                scheduleCueRefresh(cueID: tail[1])
            }

        case "cueList":
            if tail.count >= 3, tail[2] == "playbackPosition" {
                let listID = tail[1]
                // No argument means the playhead was unset — a real state, not
                // a missing value, and the display has an empty state for it.
                if let cueID = message.arguments.first?.stringValue, !cueID.isEmpty {
                    playheads[listID] = cueID
                } else {
                    playheads.removeValue(forKey: listID)
                }
                if watchedCueListID == nil { watchedCueListID = listID }
            }

        default:
            break
        }
    }

    /// Coalesces bursts of workspace-level updates into one refetch.
    private var cueListRefreshTask: Task<Void, Never>?

    private func debouncedCueListRefresh() async {
        cueListRefreshTask?.cancel()
        cueListRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            try? await self.refreshCueLists()
        }
    }

    /// Refetching a single cue is handled in Milestone 5, where the cue graph
    /// knows whether the cue is on screen and therefore worth a round trip.
    private func scheduleCueRefresh(cueID: String) {
        guard cueID == currentPlayheadCueID else { return }
        Task { [weak self] in
            await self?.refreshPlayheadCueDetails()
        }
    }

    // MARK: - Cue data

    func refreshCueLists() async throws {
        guard let workspaceID = workspace?.uniqueID else { return }
        let reply = try await request(
            OSCMessage("/workspace/\(workspaceID)/cueLists"),
            as: [Cue].self
        )
        cueLists = reply.data ?? []

        if watchedCueListID == nil {
            watchedCueListID = cueLists.first?.uniqueID
        }
    }

    /// The cue ID at the playhead of the watched cue list, if any.
    var currentPlayheadCueID: String? {
        guard let watchedCueListID else { return nil }
        return playheads[watchedCueListID]
    }

    /// A flattened graph of the watched cue list, for playhead neighbourhood
    /// lookups. Rebuilt when the cue lists or the watched list change.
    var watchedGraph: CueGraph? {
        guard let watchedCueListID,
              let list = cueLists.first(where: { $0.uniqueID == watchedCueListID })
        else { return nil }
        return CueGraph(cueList: list)
    }

    /// The cue standing by at the playhead — the app's headline value.
    ///
    /// `nil` covers three distinct situations the display distinguishes: not
    /// connected, no cue list selected, and a cue list whose playhead is unset.
    var playheadCue: Cue? {
        guard let cueID = currentPlayheadCueID else { return nil }
        return watchedGraph?.cue(withID: cueID) ?? cueLists.firstCue(withID: cueID)
    }

    /// Fills in the detail-pill properties for the cue at the playhead.
    ///
    /// Only the keys for enabled pills are requested, which is what keeps this
    /// cheap enough to run on every playhead change.
    func refreshPlayheadCueDetails() async {
        guard let workspaceID = workspace?.uniqueID,
              let cueID = currentPlayheadCueID
        else { return }

        let keys = preferences.visiblePills.compactMap(\.qlabKey)
        guard !keys.isEmpty else { return }

        guard let keysJSON = try? JSONEncoder().encode(keys),
              let keysString = String(data: keysJSON, encoding: .utf8)
        else { return }

        do {
            let reply = try await request(
                OSCMessage(
                    "/workspace/\(workspaceID)/cue_id/\(cueID)/valuesForKeys",
                    [.string(keysString)]
                ),
                as: QLabCueValues.self
            )
            guard let values = reply.data else { return }
            cueLists.applyValues(values, toCueWithID: cueID)
        } catch {
            // A failed detail fetch degrades the pills, not the cue number —
            // the headline stays correct even when the extras don't arrive.
            logger.debug("valuesForKeys failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.preferences.heartbeatInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self.sendThump()
            }
        }
    }

    private func sendThump() async {
        guard let workspaceID = workspace?.uniqueID, connection != nil else { return }

        let sentAt = Date()
        do {
            let reply = try await request(
                OSCMessage("/workspace/\(workspaceID)/thump"),
                as: String.self
            )
            guard reply.data == "thump" || reply.status.isSuccess else { return }

            let roundTrip = Date().timeIntervalSince(sentAt)
            recordThump(roundTrip: roundTrip)
        } catch {
            missedThumps += 1
            // One missed thump on a busy show network is noise. Three in a row
            // is a real signal, and matches the TCP keepalive count.
            if missedThumps >= 3, status.hasLiveData {
                status = .degraded(
                    reason: "QLab has missed \(missedThumps) heartbeats in a row."
                )
            }
        }
    }

    private func recordThump(roundTrip: TimeInterval) {
        heartbeatCount += 1
        lastThumpDate = Date()
        lastRoundTrip = roundTrip
        missedThumps = 0

        // A short rolling window, so the mean reflects the network now rather
        // than an hour ago.
        roundTripSamples.append(roundTrip)
        if roundTripSamples.count > 20 { roundTripSamples.removeFirst() }
        meanRoundTrip = roundTripSamples.reduce(0, +) / Double(roundTripSamples.count)

        if case .degraded = status { status = .connected }
    }

    private func resetHeartbeatStatistics() {
        heartbeatCount = 0
        lastThumpDate = nil
        lastRoundTrip = nil
        meanRoundTrip = nil
        missedThumps = 0
        roundTripSamples.removeAll()
    }

    // MARK: - Reconnection

    /// Exponential backoff with jitter, capped so a long outage doesn't leave
    /// the app waiting many minutes after QLab comes back.
    private func scheduleReconnect() {
        guard let target = currentTarget else { return }
        reconnectTask?.cancel()

        backoffAttempt += 1
        let base = min(0.5 * pow(2, Double(backoffAttempt - 1)), 30)
        let jitter = Double.random(in: 0...(base * 0.25))
        let delay = base + jitter

        logger.info("Reconnecting in \(delay, format: .fixed(precision: 1))s (attempt \(self.backoffAttempt))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectCount += 1
            await self.connect(
                to: target.server,
                workspaceID: target.workspaceID,
                passcode: target.passcode
            )
        }
    }

    // MARK: - Errors

    private func recordError(_ error: any Error) {
        lastErrorDescription = describe(error)
        lastErrorDate = Date()
    }

    private func describe(_ error: any Error) -> String {
        if let described = error as? any CustomStringConvertible {
            return described.description
        }
        return error.localizedDescription
    }
}
