import Foundation
import Network
import os

@Observable
@MainActor
final class QLabClient {
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "QLabClient")
    private let preferences: Preferences
    private let log: ActivityLog

    private(set) var status: ConnectionStatus = .offline

    private(set) var workspace: QLabWorkspaceInfo?

    private(set) var qlabVersion: String?

    private(set) var cueLists: [Cue] = []

    private(set) var playheads: [String: PlayheadState] = [:]

    var watchedCueListID: String? {
        didSet {
            if let watchedCueListID { preferredCueListID = watchedCueListID }
            invalidateWatchedGraph()
        }
    }

    private var watchedGraphCache: (cueListID: String, graph: CueGraph)?

    private(set) var connectedSince: Date?
    private(set) var usedPasscode = false
    private(set) var accessLevel: QLabAccessLevel = .unspecified
    private(set) var isSubscribedToUpdates = false
    private(set) var reconnectCount = 0
    private(set) var lastErrorDescription: String?
    private(set) var lastErrorDate: Date?

    private(set) var droppedEventCount = 0

    private(set) var lateReplyCount = 0

    private(set) var heartbeatCount = 0
    private(set) var lastThumpDate: Date?

    private(set) var nextThumpWindow: Range<Date>?

    private(set) var lastRoundTrip: TimeInterval?
    private(set) var meanRoundTrip: TimeInterval?
    private(set) var missedThumps = 0
    private var roundTripSamples: [TimeInterval] = []

    var onPasscodeRequired: ((Bool) -> Void)?

    enum SessionEnd: Hashable, Sendable {
        case workspaceClosed
    }

    var onSessionEnded: ((SessionEnd) -> Void)?

    var isSessionActive: Bool { currentTarget != nil }

    private var connection: QLabConnection?
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var pending: [UUID: PendingRequest] = [:]
    private var pendingByAddress: [String: [UUID]] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    private var abandonedReplyDeadlines: [String: [ContinuousClock.Instant]] = [:]

    private var currentTarget: (server: QLabServer, workspaceID: String, passcode: String?)?

    private var preferredCueListID: String?

    private var backoffAttempt = 0

    init(preferences: Preferences, log: ActivityLog) {
        self.preferences = preferences
        self.log = log
    }

    func fetchWorkspaces(from server: QLabServer) async throws -> [QLabWorkspaceInfo] {
        let probe = QLabConnection(endpoint: server.endpoint)
        defer { Task { await probe.cancel() } }

        let stream = await probe.start()
        try await probe.waitUntilReady(timeout: preferences.requestTimeout)

        let reply = try await probeRequest(
            OSCMessage("/workspaces"),
            as: [QLabWorkspaceInfo].self,
            over: probe,
            stream: stream
        )
        return reply.data ?? []
    }

    func connect(to server: QLabServer, workspaceID: String, passcode: String?) async {
        tearDownSession(sendDisconnect: true)
        reconnectTask?.cancel()
        reconnectTask = nil

        currentTarget = (server, workspaceID, passcode)
        status = .connecting

        let connection = QLabConnection(endpoint: server.endpoint)
        self.connection = connection
        await connection.setEventsDroppedHandler { [weak self] lost in
            await self?.handleEventsDropped(lost, on: connection)
        }
        let stream = await connection.start()

        do {
            try await connection.waitUntilReady(timeout: preferences.requestTimeout)
            guard self.connection === connection else { return }
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard let self, self.connection === connection else { return }
                    await self.handle(event)
                }
            }
            try await performHandshake(workspaceID: workspaceID, passcode: passcode)
        } catch {
            guard self.connection === connection else { return }
            await handleHandshakeFailure(error)
        }
    }

    func reconnect() async {
        guard let target = currentTarget else { return }
        await connect(
            to: target.server,
            workspaceID: target.workspaceID,
            passcode: target.passcode
        )
    }

    func disconnect(sendDisconnect: Bool = true) {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentTarget = nil
        backoffAttempt = 0

        tearDownSession(sendDisconnect: sendDisconnect)

        status = .offline
    }

    private static let goodbyeMessages = [
        OSCMessage("/forgetMeNot", [.false]),
        OSCMessage("/udpKeepAlive", [.false]),
        OSCMessage("/disconnect"),
    ]

    private func tearDownSession(sendDisconnect: Bool) {
        cueListRefreshTask?.cancel()
        cueListRefreshTask = nil
        playheadDetailsTask?.cancel()
        playheadDetailsTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        nextThumpWindow = nil
        overflowRecoveryTask?.cancel()
        overflowRecoveryTask = nil
        lastOverflowRecovery = nil
        droppedEventCount = 0

        let connection = self.connection
        if sendDisconnect, status.hasLiveData, let connection {
            Task { [weak self] in
                for message in Self.goodbyeMessages {
                    guard let byteCount = try? await connection.send(message) else { continue }
                    self?.log.record(
                        OSCEvent(message: message, direction: .outbound, byteCount: byteCount)
                    )
                }
                await connection.cancel()
            }
        } else if let connection {
            Task { await connection.cancel() }
        }

        eventTask?.cancel()
        eventTask = nil
        self.connection = nil

        failAllPendingRequests(with: RequestFailure.disconnected)
        abandonedReplyDeadlines.removeAll()

        workspace = nil
        accessLevel = .unspecified
        usedPasscode = false
        invalidateLiveSessionData()
        resetHeartbeatStatistics()
    }

    private func invalidateLiveSessionData() {
        isSubscribedToUpdates = false
        connectedSince = nil
        cueLists = []
        invalidateWatchedGraph()
        playheads = [:]
        watchedCueListID = nil
    }

    private func handleSessionLost(reason: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        nextThumpWindow = nil
        cueListRefreshTask?.cancel()
        cueListRefreshTask = nil
        playheadDetailsTask?.cancel()
        playheadDetailsTask = nil
        overflowRecoveryTask?.cancel()
        overflowRecoveryTask = nil
        failAllPendingRequests(with: RequestFailure.disconnected)
        invalidateLiveSessionData()

        status = .failed(reason: reason)
        scheduleReconnect()
    }

    nonisolated enum EventLossRecovery: Hashable, Sendable {
        case resynchronize
        case rebuildSession
    }

    nonisolated static let overflowEscalationWindow: Duration = .seconds(10)

    nonisolated static func recovery(
        after previous: ContinuousClock.Instant?,
        at now: ContinuousClock.Instant
    ) -> EventLossRecovery {
        guard let previous, now - previous < overflowEscalationWindow else {
            return .resynchronize
        }
        return .rebuildSession
    }

    private var lastOverflowRecovery: ContinuousClock.Instant?

    private var overflowRecoveryTask: Task<Void, Never>?

    private func handleEventsDropped(_ lost: Int, on connection: QLabConnection) {
        guard self.connection === connection else { return }
        handleEventLoss(lost)
    }

    private static let overflowRecoveryDelay: Duration = .milliseconds(250)

    func handleEventLoss(_ lost: Int) {
        guard let connection else { return }

        droppedEventCount += lost
        logger.warning(
            "Event buffer overflowed; \(lost, privacy: .public) event(s) lost"
        )

        overflowRecoveryTask?.cancel()
        overflowRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.overflowRecoveryDelay)
            guard !Task.isCancelled, let self else { return }
            await self.recoverFromEventLoss(on: connection)
        }
    }

    private func recoverFromEventLoss(on connection: QLabConnection) async {
        guard self.connection === connection, status.hasLiveData else { return }

        let now = ContinuousClock.now
        let recovery = Self.recovery(after: lastOverflowRecovery, at: now)
        lastOverflowRecovery = now

        switch recovery {
        case .rebuildSession:
            logger.warning("Event buffer overflowed again; rebuilding the session")
            overflowRecoveryTask = nil
            await reconnect()

        case .resynchronize:
            logger.info("Resynchronizing after event loss")
            try? await refreshCueData()
        }
    }

    private func handleWorkspaceClosed() {
        disconnect(sendDisconnect: false)
        status = .workspaceClosed
        onSessionEnded?(.workspaceClosed)
    }

    private func performHandshake(workspaceID: String, passcode: String?) async throws {
        guard let connection else { throw RequestFailure.disconnected }

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

        let connectMessage = passcode.map {
            OSCMessage("/workspace/\(workspaceID)/connect", [.string($0)])
        } ?? OSCMessage("/workspace/\(workspaceID)/connect")

        let connectReply = try await request(connectMessage, as: String.self)
        let connectData = connectReply.data ?? ""

        if connectReply.status.isSuccess,
           let level = QLabAccessLevel(connectReplyData: connectData) {
            accessLevel = level
            usedPasscode = passcode != nil
        } else if connectData == "badpass" {
            requirePasscode()
            throw RequestFailure.passcodeRejected
        } else {
            throw RequestFailure.handshakeFailed(
                step: "connect",
                detail: connectData.isEmpty ? "no reply data" : connectData
            )
        }

        try await sendWithoutReply(OSCMessage("/forgetMeNot", [.true]))
        try await sendWithoutReply(OSCMessage("/udpKeepAlive", [.true]))

        _ = try await request(
            OSCMessage("/alwaysReply", [.true]),
            as: QLabEmptyPayload.self
        )

        let updatesReply = try await request(
            OSCMessage("/updates", [.true]),
            as: QLabEmptyPayload.self
        )

        let playheadReply = try await request(
            OSCMessage("/listen/playhead"),
            as: QLabEmptyPayload.self
        )
        isSubscribedToUpdates = updatesReply.status.isSuccess
            && playheadReply.status.isSuccess

        try await refreshCueData()
        guard self.connection === connection else { throw RequestFailure.disconnected }

        connectedSince = Date()
        backoffAttempt = 0
        status = .connected
        startHeartbeat()

        logger.info("Connected to workspace \(match.displayName, privacy: .public)")
    }

    private func handleHandshakeFailure(_ error: any Error) async {
        recordError(error)

        switch error {
        case RequestFailure.passcodeRejected, RequestFailure.passcodeRequired:
            break

        case RequestFailure.workspaceUnavailable(let id):
            logger.info("Workspace \(id, privacy: .public) is no longer open")
            handleWorkspaceClosed()

        default:
            status = .failed(reason: error.operatorDescription)
            scheduleReconnect()
        }
    }

    private struct PendingRequest {
        let correlationKey: String
        let continuation: CheckedContinuation<OSCMessage, any Error>
    }

    enum RequestFailure: Error, CustomStringConvertible {
        case disconnected
        case timedOut(address: String)
        case passcodeRequired
        case passcodeRejected
        case workspaceUnavailable(id: String)
        case handshakeFailed(step: String, detail: String)
        case replyUnreadable(String)

        var description: String {
            switch self {
            case .disconnected: "Disconnected from QLab."
            case .timedOut(let address): "QLab did not answer \(address) in time."
            case .passcodeRequired: "This workspace needs a passcode."
            case .passcodeRejected: "That passcode was not accepted."
            case .workspaceUnavailable(let id): "Workspace \(id) is no longer open in QLab."
            case .handshakeFailed(let step, let detail): "Handshake failed at \(step): \(detail)"
            case .replyUnreadable(let detail): detail
            }
        }
    }

    private func sendWithoutReply(_ message: OSCMessage) async throws {
        guard let connection else { throw RequestFailure.disconnected }
        let byteCount = try await connection.send(message)
        log.record(OSCEvent(message: message, direction: .outbound, byteCount: byteCount))
    }

    @discardableResult
    private func request<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        guard let connection else { throw RequestFailure.disconnected }
        let replyMessage = try await sendAndAwaitReply(message, over: connection)
        guard self.connection === connection else { throw RequestFailure.disconnected }

        // JSON decoding can be substantial for cue-list replies. Keep it off
        // the main actor so decoding does not compete with SwiftUI rendering.
        do {
            let reply = try await Task.detached(priority: .userInitiated) {
                try QLabReplyParser.parse(replyMessage, as: payloadType)
            }.value
            return try validateSessionReply(reply)
        } catch {
            // Error/denied replies commonly omit the requested payload. Parse
            // the small envelope only in that failure path so authorization
            // errors retain their specific behavior.
            let envelope = try await Task.detached(priority: .userInitiated) {
                try QLabReplyParser.parse(replyMessage, as: QLabEmptyPayload.self)
            }.value
            _ = try validateSessionReply(envelope)
            throw error
        }
    }

    func validateSessionReply<Payload: Decodable & Sendable>(
        _ reply: QLabReply<Payload>
    ) throws -> QLabReply<Payload> {
        if reply.status == .denied {
            requirePasscode()
            throw RequestFailure.passcodeRequired
        }
        guard reply.status.isSuccess else {
            throw RequestFailure.handshakeFailed(
                step: reply.address, detail: "QLab returned \(reply.status)."
            )
        }
        return reply
    }

    // Kept as a convenience for callers that already have a raw OSC message.
    func validateSessionReply<Payload: Decodable & Sendable>(
        _ message: OSCMessage, as payloadType: Payload.Type
    ) throws -> QLabReply<Payload> {
        let envelope = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        guard envelope.status.isSuccess else {
            _ = try validateSessionReply(envelope)
            throw RequestFailure.handshakeFailed(
                step: envelope.address, detail: "QLab returned (envelope.status)."
            )
        }
        return try validateSessionReply(
            QLabReplyParser.parse(message, as: payloadType)
        )
    }

    private func requirePasscode() {
        if case .needsPasscode = status { return }

        let rejected = currentTarget?.passcode != nil
        disconnect(sendDisconnect: false)
        status = .needsPasscode(rejected: rejected)
        recordError(rejected ? RequestFailure.passcodeRejected : RequestFailure.passcodeRequired)
        onPasscodeRequired?(rejected)
    }

    private func probeRequest<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type,
        over connection: QLabConnection,
        stream: AsyncStream<QLabConnection.Event>
    ) async throws -> QLabReply<Payload> {
        let byteCount = try await connection.send(message)
        log.record(OSCEvent(message: message, direction: .outbound, byteCount: byteCount))

        let deadline = Task { [weak self] in
            guard let timeout = self?.preferences.requestTimeout else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await connection.cancel()
        }
        defer { deadline.cancel() }

        for await event in stream {
            guard case .received(let incoming, let bytes) = event else { continue }
            log.record(OSCEvent(message: incoming, direction: .inbound, byteCount: bytes))

            let expected = QLabReplyParser.correlationKey(for: message.address)
            guard let echoed = QLabReplyParser.correlationAddress(of: incoming),
                  QLabReplyParser.correlationKey(for: echoed) == expected
            else { continue }
            do {
                return try await Task.detached(priority: .userInitiated) {
                    try QLabReplyParser.parse(incoming, as: payloadType)
                }.value
            } catch {
                throw RequestFailure.replyUnreadable(error.operatorDescription)
            }
        }

        try Task.checkCancellation()
        throw RequestFailure.timedOut(address: message.address)
    }

    private func sendAndAwaitReply(
        _ message: OSCMessage,
        over connection: QLabConnection
    ) async throws -> OSCMessage {
        let id = UUID()
        // QLab echoes the request path instead of a request ID; normalize that path for correlation.
        let key = QLabReplyParser.correlationKey(for: message.address)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pending[id] = PendingRequest(correlationKey: key, continuation: continuation)
                pendingByAddress[key, default: []].append(id)

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

                    guard self.pending[id] != nil else { return }

                    self.timeoutTasks[id] = Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(for: .seconds(self.preferences.requestTimeout))
                        guard !Task.isCancelled else { return }
                        self.timeOut(requestID: id, address: message.address)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.fail(requestID: id, with: CancellationError())
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

    private func timeOut(requestID id: UUID, address: String) {
        guard let request = removePending(id) else { return }
        abandonedReplyDeadlines[request.correlationKey, default: []]
            .append(ContinuousClock.now + .seconds(preferences.requestTimeout))
        request.continuation.resume(throwing: RequestFailure.timedOut(address: address))
    }

    private func consumeAbandonedReply(forKey key: String) -> Bool {
        guard var deadlines = abandonedReplyDeadlines[key] else { return false }

        let now = ContinuousClock.now
        deadlines.removeAll { $0 < now }
        defer {
            if deadlines.isEmpty {
                abandonedReplyDeadlines.removeValue(forKey: key)
            } else {
                abandonedReplyDeadlines[key] = deadlines
            }
        }

        guard !deadlines.isEmpty else { return false }
        deadlines.removeFirst()
        return true
    }

    private func removePending(_ id: UUID) -> PendingRequest? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return nil }
        pendingByAddress[request.correlationKey]?.removeAll { $0 == id }
        if pendingByAddress[request.correlationKey]?.isEmpty == true {
            pendingByAddress.removeValue(forKey: request.correlationKey)
        }
        return request
    }

    private func failAllPendingRequests(with error: any Error) {
        for id in pending.keys {
            fail(requestID: id, with: error)
        }
    }

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
            if status.hasLiveData {
                status = .degraded(reason: "Waiting for the network: \(error.operatorDescription)")
            }

        case .failed(let error):
            recordError(error)
            if status.hasLiveData {
                handleSessionLost(reason: error.operatorDescription)
            } else {
                failAllPendingRequests(with: error)
            }

        case .cancelled:
            if status.hasLiveData {
                handleSessionLost(reason: "QLab closed the connection.")
            } else {
                failAllPendingRequests(with: RequestFailure.disconnected)
            }

        default:
            break
        }
    }

    private func route(_ message: OSCMessage) async {
        if QLabReplyParser.isReply(message) {
            guard let address = QLabReplyParser.oscCorrelationAddress(of: message) else {
                return
            }
            let key = QLabReplyParser.correlationKey(for: address)

            if consumeAbandonedReply(forKey: key) {
                lateReplyCount += 1
                logger.debug(
                    "Dropped a late reply for \(key, privacy: .public) after its request timed out"
                )
                return
            }

            if let id = pendingByAddress[key]?.first {
                complete(requestID: id, with: message)
            }
            return
        }

        if message.address == "/qlab/event/workspace/playhead" {
            handleBroadcastPlayhead(message)
            return
        }

        if message.address.hasPrefix("/update/") {
            await handleUpdate(message)
        }
    }

    private func handleBroadcastPlayhead(_ message: OSCMessage) {
        guard message.arguments.count >= 3,
              let cueID = message.arguments[2].stringValue
        else { return }

        guard let listID = cueLists.first(where: {
            $0.children.firstCue(withID: cueID) != nil
        })?.uniqueID else {
            logger.info(
                """
                Broadcast playhead names cue \(cueID, privacy: .public), which is in no \
                known cue list; refetching
                """
            )
            scheduleCueListRefresh()
            return
        }

        setPlayhead(cueID, forCueListID: listID)
        if watchedCueListID == nil {
            watchedCueListID = listID
        }

        schedulePlayheadDetailsRefresh()
    }

    private static let playheadDetailsDebounce: Duration = .milliseconds(60)

    private var playheadDetailsTask: Task<Void, Never>?

    private func schedulePlayheadDetailsRefresh() {
        playheadDetailsTask?.cancel()
        playheadDetailsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.playheadDetailsDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.refreshPlayheadCueDetails()
        }
    }

    private func handleUpdate(_ message: OSCMessage) async {
        let components = message.addressComponents
        guard components.count >= 3,
              components[0] == "update",
              components[1] == "workspace"
        else { return }

        let tail = Array(components.dropFirst(3))

        switch tail.first {
        case nil:
            scheduleCueListRefresh()

        case "disconnect":
            logger.info("QLab asked us to disconnect")
            handleWorkspaceClosed()

        case "cue_id":
            scheduleCueListRefresh()

        case "cueList":
            if tail.count >= 3, tail[2] == "playbackPosition" {
                let listID = tail[1]
                setPlayhead(message.arguments.first?.stringValue, forCueListID: listID)
                if watchedCueListID == nil { watchedCueListID = listID }

                schedulePlayheadDetailsRefresh()
            }

        default:
            break
        }
    }

    private var cueListRefreshTask: Task<Void, Never>?

    private func scheduleCueListRefresh() {
        cueListRefreshTask?.cancel()
        cueListRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.refreshCueData()
            } catch is CancellationError {
                return
            } catch {
                self.logger.warning(
                    "Debounced cue refresh failed: \(error.operatorDescription, privacy: .public)"
                )
            }
        }
    }

    private var cueDataGeneration = 0

    func refreshCueData() async throws {
        cueDataGeneration += 1
        let generation = cueDataGeneration

        try await refreshCueLists()

        guard generation == cueDataGeneration else { return }
        await refreshPlayheadCueDetails()
    }

    func refreshCueLists() async throws {
        guard let workspaceID = workspace?.uniqueID else { return }
        let reply = try await request(
            OSCMessage("/workspace/\(workspaceID)/cueLists"),
            as: [Cue].self
        )
        var refreshed = reply.data ?? []

        if let cueID = currentPlayheadCueID,
           let previous = cueLists.firstCue(withID: cueID) {
            refreshed.applyValues(previous.detailValues, toCueWithID: cueID)
        }

        cueLists = refreshed
        invalidateWatchedGraph()

        let liveListIDs = Set(cueLists.map(\.uniqueID))
        playheads = playheads.filter { liveListIDs.contains($0.key) }

        reconcileWatchedCueList()

        await refreshPlayheads()
    }

    private func reconcileWatchedCueList() {
        if let watchedCueListID,
           cueLists.contains(where: { $0.uniqueID == watchedCueListID }) {
            return
        }

        let preferred = preferredCueListID
        watchedCueListID = preferred.flatMap { id in
            cueLists.contains { $0.uniqueID == id } ? id : nil
        } ?? cueLists.first?.uniqueID

        preferredCueListID = preferred
    }

    func refreshPlayheads() async {
        guard let workspaceID = workspace?.uniqueID else { return }
        let session = connection

        for list in cueLists {
            guard !Task.isCancelled, connection === session else { return }

            do {
                let reply = try await request(
                    OSCMessage(
                        "/workspace/\(workspaceID)/cue_id/\(list.uniqueID)/playbackPositionID"
                    ),
                    as: String.self
                )

                guard reply.status.isSuccess else {
                    logger.warning(
                        """
                        playbackPositionID for \(list.uniqueID, privacy: .public) \
                        answered \(String(describing: reply.status), privacy: .public)
                        """
                    )
                    playheads[list.uniqueID] = .unknown(
                        reason: "QLab answered \(reply.status) for this cue list."
                    )
                    continue
                }

                setPlayhead(reply.data, forCueListID: list.uniqueID)
            } catch is CancellationError {
                return
            } catch {
                logger.warning(
                    """
                    playbackPositionID failed for \(list.uniqueID, privacy: .public): \
                    \(error.operatorDescription, privacy: .public)
                    """
                )
                playheads[list.uniqueID] = .unknown(reason: error.operatorDescription)
            }
        }
    }

    private func setPlayhead(_ cueID: String?, forCueListID listID: String) {
        guard let cueID, !cueID.isEmpty, cueID != "none" else {
            playheads[listID] = .unset
            return
        }
        let nextState = PlayheadState.cue(cueID)
        guard playheads[listID] != nextState else { return }
        playheads[listID] = nextState
    }

    var watchedPlayhead: PlayheadState? {
        guard let watchedCueListID else { return nil }
        return playheads[watchedCueListID]
    }

    var currentPlayheadCueID: String? {
        watchedPlayhead?.cueID
    }

    var watchedGraph: CueGraph? {
        guard let watchedCueListID else { return nil }

        if let cached = watchedGraphCache,
           cached.cueListID == watchedCueListID {
            return cached.graph
        }

        guard let list = cueLists.first(where: { $0.uniqueID == watchedCueListID }) else {
            return nil
        }

        let graph = CueGraph(cueList: list)
        watchedGraphCache = (cueListID: watchedCueListID, graph: graph)
        return graph
    }

    private func invalidateWatchedGraph() {
        watchedGraphCache = nil
    }

    var playheadCue: Cue? {
        guard let cueID = currentPlayheadCueID else { return nil }
        return watchedGraph?.cue(withID: cueID) ?? cueLists.firstCue(withID: cueID)
    }

    var liveCue: Cue? {
        guard status.hasLiveData else { return nil }
        return playheadCue
    }

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
            invalidateWatchedGraph()
        } catch {
            logger.debug("valuesForKeys failed: \(error.operatorDescription, privacy: .public)")
        }
    }

    private static let degradedThumpThreshold = 3

    private static let lostThumpThreshold = 6

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.preferences.heartbeatInterval
                let start = Date()
                self.nextThumpWindow = start..<start.addingTimeInterval(interval)
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
            guard reply.data == "thump" else {
                throw RequestFailure.handshakeFailed(step: "thump", detail: "Unexpected heartbeat reply.")
            }

            let roundTrip = Date().timeIntervalSince(sentAt)
            recordThump(roundTrip: roundTrip)
        } catch {
            guard status.hasLiveData else { return }
            missedThumps += 1

            if missedThumps >= Self.lostThumpThreshold {
                recordError(error)
                handleSessionLost(
                    reason: "QLab stopped answering heartbeats for this workspace."
                )
            } else if missedThumps >= Self.degradedThumpThreshold {
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

        roundTripSamples.append(roundTrip)
        if roundTripSamples.count > 20 { roundTripSamples.removeFirst() }
        meanRoundTrip = roundTripSamples.reduce(0, +) / Double(roundTripSamples.count)

        if case .degraded = status { status = .connected }
    }

    private func resetHeartbeatStatistics() {
        heartbeatCount = 0
        lastThumpDate = nil
        nextThumpWindow = nil
        lastRoundTrip = nil
        meanRoundTrip = nil
        missedThumps = 0
        roundTripSamples.removeAll()
    }

    private func scheduleReconnect() {
        guard let target = currentTarget else { return }
        reconnectTask?.cancel()

        backoffAttempt += 1
        let base = min(0.5 * pow(2, Double(backoffAttempt - 1)), 30)
        let jitter = Double.random(in: 0...(base * 0.25))
        let delay = base + jitter

        logger.info("Reconnecting in \(delay, format: .fixed(precision: 1))s (attempt \(self.backoffAttempt))")

        let reason: String
        if case .failed(let failureReason) = status {
            reason = failureReason
        } else {
            reason = lastErrorDescription ?? "The connection to QLab dropped."
        }
        status = .reconnecting(attempt: backoffAttempt, reason: reason)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.reconnectCount += 1
            await self.connect(
                to: target.server,
                workspaceID: target.workspaceID,
                passcode: target.passcode
            )
        }
    }

    private func recordError(_ error: any Error) {
        lastErrorDescription = error.operatorDescription
        lastErrorDate = Date()
    }

}

