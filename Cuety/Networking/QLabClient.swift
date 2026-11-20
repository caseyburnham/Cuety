import Foundation
import Network
import os
import ShowControlCore

@Observable
@MainActor
final class QLabClient {
    private let logger = Logger(category: "QLabClient")
    private let preferences: Preferences
    private let log: ActivityLog
    let eventHistory = EventHistory()

    private(set) var status: ConnectionStatus = .offline

    private(set) var workspace: QLabWorkspaceInfo?

    private(set) var cueLists: [Cue] = []

    /// O(1) lookup index over `cueLists`, rebuilt off the main actor on each
    /// structural refresh.
    @ObservationIgnored private var workspaceIndex = WorkspaceIndex(cueLists: [])

    /// Every cue in every list, counted once per structural snapshot.
    private(set) var totalCueCount = 0

    private(set) var playheads: [String: PlayheadState] = [:]
    @ObservationIgnored private var playheadRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var playheadRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var cueDetailInvalidationPending = false
    @ObservationIgnored private var cueDetailInvalidationGeneration: UInt64 = 0

    /// Lightweight sidebar metadata for a top-level cue list or cart. Kept
    /// separate from `cueLists` so detail refreshes on individual cues never
    /// force the sidebar `List` to diff or copy full `Cue` subtrees.
    struct CueListSummary: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String?
        let isCueCart: Bool

        init(list: Cue) {
            self.id = list.uniqueID
            self.displayName = list.displayName
            self.isCueCart = list.isCueCart
        }
    }

    /// Sidebar playhead readout for a single cue list, updated only when that
    /// list's playhead state or standing-by cue number/name changes.
    struct PlayheadSummary: Equatable, Sendable {
        let state: PlayheadState
        let cueDisplayNumber: String?
        let cueDisplayName: String?
        let hasCue: Bool
    }

    /// Derived state for the watched cue list, kept in sync only when its own
    /// values change so updates to unrelated cue lists or off-standby cues do
    /// not invalidate display views.
    private(set) var cueListSummaries: [CueListSummary] = []
    private(set) var playheadSummaries: [String: PlayheadSummary] = [:]
    private(set) var watchedPlayhead: PlayheadState?
    private(set) var watchedGraph: CueGraph?
    private(set) var playheadCue: Cue?
    private(set) var watchedCueListName: String?
    private(set) var isWatchingCueCart = false

    var watchedCueListID: String? {
        didSet {
            if let watchedCueListID { preferredCueListID = watchedCueListID }
            syncWatchedState()
        }
    }

    private(set) var connectedSince: Date?
    private(set) var usedPasscode = false
    private(set) var accessLevel: QLabAccessLevel = .unspecified
    private(set) var reconnectCount = 0
    private(set) var lastErrorDescription: String?
    private(set) var lastErrorDate: Date?

    private(set) var droppedEventCount = 0

    private(set) var lateReplyCount = 0

    private(set) var heartbeatCount = 0
    private(set) var lastThumpDate: Date?

    private(set) var lastRoundTrip: TimeInterval?
    private(set) var meanRoundTrip: TimeInterval?
    private(set) var missedThumps = 0
    @ObservationIgnored private var roundTripSamples: [TimeInterval] = []

    var onPasscodeRequired: ((Bool) -> Void)?

    enum SessionEnd: Hashable, Sendable {
        case workspaceClosed
    }

    var onSessionEnded: ((SessionEnd) -> Void)?

    var isSessionActive: Bool { currentTarget != nil }

    func hasLiveSession(for selection: WorkspaceSelection) -> Bool {
        guard status.hasLiveData,
              let currentTarget,
              currentTarget.server.id == selection.serverID,
              currentTarget.workspaceID == selection.workspaceID,
              workspace?.uniqueID == selection.workspaceID
        else { return false }
        return true
    }

    @ObservationIgnored private var connection: QLabConnection?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    @ObservationIgnored private var replies = ReplyCorrelator<CheckedContinuation<ReceivedReply, any Error>>()
    @ObservationIgnored private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestSendStates: [UUID: QLabSendState] = [:]
    @ObservationIgnored private var abandonedReplyPruneTask: Task<Void, Never>?

    private var currentTarget: (server: QLabServer, workspaceID: String, passcode: String?)?

    @ObservationIgnored private var preferredCueListID: String?

    @ObservationIgnored private var backoffAttempt = 0

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

    func connect(
        to server: QLabServer, workspaceID: String, passcode: String?,
        reconnecting: Bool = false
    ) async {
        let workspaceName = reconnecting ? workspace?.displayName ?? workspaceID : workspaceID
        if status.hasLiveData, !reconnecting {
            eventHistory.recordLifecycle(.disconnected, workspaceName: workspace?.displayName)
        }
        tearDownSession(sendDisconnect: true)
        reconnectTask?.cancel()
        reconnectTask = nil

        currentTarget = (server, workspaceID, passcode)
        status = .connecting
        eventHistory.recordLifecycle(
            reconnecting ? .reconnecting : .connecting, workspaceName: workspaceName
        )

        let connection = QLabConnection(endpoint: server.endpoint)
        self.connection = connection
        await connection.setEventsDroppedHandler { [weak self, weak connection] lost in
            guard let connection else { return }
            await self?.handleEventsDropped(lost, on: connection)
        }
        let stream = await connection.start()

        do {
            try await connection.waitUntilReady(timeout: preferences.requestTimeout)
            guard self.connection === connection else { return }
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard let self, self.connection === connection else { return }
                    self.handle(event)
                }
            }
            try await performHandshake(workspaceID: workspaceID, passcode: passcode)
        } catch {
            guard self.connection === connection else { return }
            handleHandshakeFailure(error)
        }
    }

    func reconnect() async {
        guard let target = currentTarget else { return }
        await connect(
            to: target.server,
            workspaceID: target.workspaceID,
            passcode: target.passcode,
            reconnecting: true
        )
    }

    func disconnect(sendDisconnect: Bool = true) {
        if currentTarget != nil || connection != nil {
            eventHistory.recordLifecycle(
                .disconnected, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID,
                detail: status.hasLiveData ? nil : "Connection canceled"
            )
        }
        endSession(sendDisconnect: sendDisconnect)
        status = .offline
    }

    private func endSession(sendDisconnect: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentTarget = nil
        backoffAttempt = 0

        tearDownSession(sendDisconnect: sendDisconnect)
    }

    private static let goodbyeMessages = [
        OSCMessage("/forgetMeNot", [.false]),
        OSCMessage("/udpKeepAlive", [.false]),
        OSCMessage("/disconnect"),
    ]

    /// Stops the work a session schedules for itself: heartbeats, debounced
    /// refreshes and event-loss recovery.
    private func cancelSessionTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        cueListRefreshTask?.cancel()
        cueListRefreshTask = nil
        playheadDetailsTask?.cancel()
        playheadDetailsTask = nil
        cancelUnconfirmedDetailsRefetch()
        overflowRecoveryTask?.cancel()
        overflowRecoveryTask = nil
    }

    private func tearDownSession(sendDisconnect: Bool) {
        cancelSessionTasks()
        eventHistory.endObservation()
        lastOverflowRecovery = nil
        droppedEventCount = 0

        let connection = self.connection
        if sendDisconnect, status.hasLiveData, let connection {
            let log = self.log
            Task {
                for message in Self.goodbyeMessages {
                    try? await Self.send(message, over: connection, loggingTo: log)
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
        abandonedReplyPruneTask?.cancel()
        abandonedReplyPruneTask = nil
        replies.forgetOwedReplies()

        workspace = nil
        accessLevel = .unspecified
        usedPasscode = false
        invalidateLiveSessionData()
        resetHeartbeatMetrics()
    }

    private func invalidateLiveSessionData() {
        connectedSince = nil
        cueLists = []
        workspaceIndex = WorkspaceIndex(cueLists: [])
        totalCueCount = 0
        cuesWithLoadedDetails.removeAll()
        pendingCueDetailIDs.removeAll()
        cueDetailRevisions.removeAll()
        activeCueDetailIDs.removeAll()
        playheads = [:]
        playheadRevisions = [:]
        cueDetailInvalidationPending = false
        cueDetailInvalidationGeneration &+= 1
        watchedCueListID = nil
        syncWatchedState()
    }

    private func handleSessionLost(reason: String) {
        eventHistory.recordLifecycle(
            .connectionLost, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID,
            detail: reason
        )
        eventHistory.markIncomplete()
        tearDownSession(sendDisconnect: false)

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

    @ObservationIgnored private var lastOverflowRecovery: ContinuousClock.Instant?

    @ObservationIgnored private var overflowRecoveryTask: Task<Void, Never>?

    private func handleEventsDropped(_ lost: Int, on connection: QLabConnection) {
        guard self.connection === connection else { return }
        handleEventLoss(lost)
    }

    private static let overflowRecoveryDelay: Duration = .milliseconds(250)

    func handleEventLoss(_ lost: Int) {
        guard let connection, lost > 0 else { return }

        droppedEventCount += lost
        eventHistory.markIncomplete()
        eventHistory.recordLifecycle(
            .missedEvents, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID,
            detail: "\(lost) event\(lost == 1 ? "" : "s")"
        )
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
            // A lost event may have been an edit, so no retained detail can
            // be trusted until QLab answers for it again.
            do {
                try await refreshCueData(invalidatingDetails: true)
            } catch {
                guard !Task.isCancelled, self.connection === connection else { return }
                recordError(error)
                handleSessionLost(reason: "Cue data could not be refreshed after missed updates. \(error.localizedDescription)")
            }
        }
    }

    private func handleWorkspaceClosed() {
        eventHistory.recordLifecycle(
            .workspaceClosed, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID
        )
        eventHistory.markIncomplete()
        endSession(sendDisconnect: false)
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
        let connectMessage = passcode.map {
            OSCMessage("/workspace/\(workspaceID)/connect", [.string($0)])
        } ?? OSCMessage("/workspace/\(workspaceID)/connect")

        let connectReply = try await request(connectMessage, as: String.self)
        let connectData = connectReply.data ?? ""

        if let level = QLabAccessLevel(connectReplyData: connectData) {
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

        // Both requests throw unless QLab answered with a success status.
        try await request(
            OSCMessage("/updates", [.true]),
            as: QLabEmptyPayload.self
        )

        try await request(
            OSCMessage("/listen/playhead"),
            as: QLabEmptyPayload.self
        )
        eventHistory.beginObservation()
        for event in ["go", "panicAll", "cue/start", "cue/stop"] {
            try await request(OSCMessage("/listen/\(event)"), as: QLabEmptyPayload.self)
        }
        try await refreshCueData()
        guard self.connection === connection else { throw RequestFailure.disconnected }

        connectedSince = Date()
        backoffAttempt = 0
        status = .connected
        eventHistory.recordLifecycle(.connected, workspaceName: match.displayName)
        startHeartbeat()

        logger.info("Connected to workspace \(match.displayName, privacy: .public)")
    }

    private func handleHandshakeFailure(_ error: any Error) {
        eventHistory.markIncomplete()
        recordError(error)

        switch error {
        case RequestFailure.passcodeRejected, RequestFailure.passcodeRequired:
            break

        case RequestFailure.workspaceUnavailable(let id):
            logger.info("Workspace \(id, privacy: .public) is no longer open")
            handleWorkspaceClosed()

        default:
            eventHistory.recordLifecycle(
                .connectionFailed, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID,
                detail: error.localizedDescription
            )
            tearDownSession(sendDisconnect: false)
            status = .failed(reason: error.localizedDescription)
            scheduleReconnect()
        }
    }

    /// QLab echoes only the request path, never a request ID. If an earlier
    /// request was canceled or timed out and its answer is still owed, the
    /// next reply may be that older answer: `mayBeStale` says so.
    private struct ReceivedReply {
        let message: OSCMessage
        let mayBeStale: Bool
    }

    nonisolated enum RequestFailure: LocalizedError {
        case disconnected
        case timedOut(address: String)
        case passcodeRequired
        case passcodeRejected
        case workspaceUnavailable(id: String)
        case handshakeFailed(step: String, detail: String)
        case replyUnreadable(String)

        var errorDescription: String? {
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

    /// Sends `message` and records it in the Activity Log, which only builds
    /// the row if it is keeping rows. Static so a send can outlive the client.
    private static func send(
        _ message: OSCMessage, over connection: QLabConnection, loggingTo log: ActivityLog,
        trackedBy sendState: QLabSendState? = nil
    ) async throws {
        let byteCount = try await connection.send(message, trackedBy: sendState)
        log.record(
            direction: .outbound, byteCount: byteCount,
            event: OSCEvent(message: message, direction: .outbound, byteCount: byteCount)
        )
    }

    private func sendWithoutReply(_ message: OSCMessage) async throws {
        guard let connection else { throw RequestFailure.disconnected }
        try await Self.send(message, over: connection, loggingTo: log)
        guard self.connection === connection else { throw RequestFailure.disconnected }
    }

    @discardableResult
    private func request<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        try await requestReportingFreshness(message, as: payloadType).reply
    }

    /// As `request`, also reporting whether the reply may belong to an
    /// earlier request on the same path that timed out.
    private func requestReportingFreshness<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) async throws -> (reply: QLabReply<Payload>, mayBeStale: Bool) {
        guard let session = connection else { throw RequestFailure.disconnected }
        let received = try await requestReceivedReply(message, on: session)
        guard connection === session else { throw RequestFailure.disconnected }
        let reply = try await validateSessionReply(received.message, as: payloadType)
        return (reply, received.mayBeStale)
    }

    /// Returns correlation freshness before payload validation can apply
    /// authorization or session-loss side effects to an older reply.
    private func requestReceivedReply(
        _ message: OSCMessage,
        on expectedSession: QLabConnection
    ) async throws -> ReceivedReply {
        guard let connection, connection === expectedSession else {
            throw RequestFailure.disconnected
        }
        let received = try await sendAndAwaitReply(message, over: connection)
        guard self.connection === connection else { throw RequestFailure.disconnected }
        return received
    }

    /// The single path from a raw reply to a validated payload.
    func validateSessionReply<Payload: Decodable & Sendable>(
        _ message: OSCMessage, as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        let session = connection
        let reply: QLabReply<Payload>
        do {
            reply = try await parse(message, as: payloadType)
        } catch {
            guard connection === session else { throw RequestFailure.disconnected }
            try Task.checkCancellation()
            // Error/denied replies commonly omit the requested payload, so a
            // decoding failure is often the envelope reporting a problem.
            // Read the small envelope on its own in that path only, so
            // authorization errors retain their specific behavior.
            let envelope = try await parse(message, as: QLabEmptyPayload.self)
            guard connection === session else { throw RequestFailure.disconnected }
            try Task.checkCancellation()
            _ = try validateSessionReply(envelope)
            throw error
        }
        guard connection === session else { throw RequestFailure.disconnected }
        try Task.checkCancellation()
        return try validateSessionReply(reply)
    }

    /// JSON decoding can be substantial for cue-list replies. Keep it off the
    /// main actor so decoding does not compete with SwiftUI rendering.
    @concurrent
    private nonisolated func parse<Payload: Decodable & Sendable>(
        _ message: OSCMessage, as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        try QLabReplyParser.parse(message, as: payloadType)
    }

    private func validateSessionReply<Payload: Decodable & Sendable>(
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

    private func requirePasscode() {
        if case .needsPasscode = status { return }

        let rejected = currentTarget?.passcode != nil
        eventHistory.recordLifecycle(
            rejected ? .passcodeRejected : .passcodeRequired,
            workspaceName: workspace?.displayName ?? currentTarget?.workspaceID
        )
        eventHistory.markIncomplete()
        endSession(sendDisconnect: false)
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
        try await Self.send(message, over: connection, loggingTo: log)

        let deadline = Task { [weak self] in
            guard let timeout = self?.preferences.requestTimeout else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await connection.cancel()
        }
        defer { deadline.cancel() }

        for await event in stream {
            guard case .received(let incoming, let bytes) = event else { continue }
            log.record(
                direction: .inbound, byteCount: bytes,
                isHeartbeat: incoming.address.hasSuffix("/thump"),
                event: OSCEvent(message: incoming, direction: .inbound, byteCount: bytes)
            )

            let expected = QLabReplyParser.correlationKey(for: message.address)
            guard let echoed = QLabReplyParser.oscCorrelationAddress(of: incoming),
                  QLabReplyParser.correlationKey(for: echoed) == expected
            else { continue }
            do {
                return try await parse(incoming, as: payloadType)
            } catch {
                throw RequestFailure.replyUnreadable(error.localizedDescription)
            }
        }

        try Task.checkCancellation()
        throw RequestFailure.timedOut(address: message.address)
    }

    private func sendAndAwaitReply(
        _ message: OSCMessage,
        over connection: QLabConnection
    ) async throws -> ReceivedReply {
        let id = UUID()
        // QLab echoes the request path instead of a request ID; normalize that path for correlation.
        let key = QLabReplyParser.correlationKey(for: message.address)
        let sendState = QLabSendState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReceivedReply, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                replies.register(id, key: key, waiter: continuation)
                requestSendStates[id] = sendState

                Task { [weak self] in
                    guard let self else { return }
                    guard self.replies.isWaiting(id) else { return }
                    do {
                        try await Self.send(
                            message, over: connection, loggingTo: self.log,
                            trackedBy: sendState
                        )
                    } catch {
                        self.fail(requestID: id, with: error)
                        return
                    }

                    guard self.replies.isWaiting(id) else { return }

                    self.timeoutTasks[id] = Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(for: .seconds(self.preferences.requestTimeout))
                        guard !Task.isCancelled else { return }
                        self.timeOut(requestID: id, address: message.address)
                    }
                }
            }
        } onCancel: {
            let mayHaveBeenSent = sendState.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(requestID: id, mayHaveBeenSent: mayHaveBeenSent)
            }
        }
    }

    private func complete(requestID id: UUID, with reply: ReceivedReply) {
        removePending(id)?.waiter.resume(returning: reply)
    }

    private func fail(requestID id: UUID, with error: any Error) {
        removePending(id)?.waiter.resume(throwing: error)
    }

    private func cancel(requestID id: UUID, mayHaveBeenSent: Bool) {
        guard let request = removePending(id) else { return }
        if mayHaveBeenSent { recordAbandonedReply(forKey: request.key) }
        request.waiter.resume(throwing: CancellationError())
    }

    private func timeOut(requestID id: UUID, address: String) {
        guard let request = removePending(id) else { return }
        recordAbandonedReply(forKey: request.key)
        request.waiter.resume(throwing: RequestFailure.timedOut(address: address))
    }

    private func recordAbandonedReply(forKey key: String) {
        replies.recordAbandoned(
            key: key, until: .now + .seconds(preferences.requestTimeout)
        )
        scheduleAbandonedReplyPruning()
    }

    private static let abandonedReplyPruneInterval: Duration = .seconds(1)

    private func scheduleAbandonedReplyPruning() {
        guard abandonedReplyPruneTask == nil else { return }

        abandonedReplyPruneTask = Task { [weak self] in
            try? await Task.sleep(for: Self.abandonedReplyPruneInterval)
            guard !Task.isCancelled, let self else { return }
            self.pruneAbandonedReplyDeadlines()
        }
    }

    private func pruneAbandonedReplyDeadlines() {
        abandonedReplyPruneTask = nil
        replies.pruneOwedReplies(at: .now)
        if replies.hasOwedReplies {
            scheduleAbandonedReplyPruning()
        }
    }

    private func removePending(
        _ id: UUID
    ) -> (key: String, waiter: CheckedContinuation<ReceivedReply, any Error>)? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let sendState = requestSendStates.removeValue(forKey: id) {
            _ = sendState.cancel()
        }
        return replies.remove(id)
    }

    private func failAllPendingRequests(with error: any Error) {
        for id in replies.waitingIDs {
            fail(requestID: id, with: error)
        }
    }

    private func handle(_ event: QLabConnection.Event) {
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
            log.record(
                direction: .inbound, byteCount: byteCount,
                isHeartbeat: message.address.hasSuffix("/thump"),
                event: OSCEvent(message: message, direction: .inbound, byteCount: byteCount)
            )
            route(message)

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
                status = .degraded(reason: "Waiting for the network: \(error.localizedDescription)")
            }

        case .failed(let error):
            recordError(error)
            if status.hasLiveData {
                handleSessionLost(reason: error.localizedDescription)
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

    private func route(_ message: OSCMessage) {
        if QLabReplyParser.isReply(message) {
            guard let address = QLabReplyParser.oscCorrelationAddress(of: message) else {
                return
            }
            let key = QLabReplyParser.correlationKey(for: address)

            // A request still waiting on this key always gets the reply, and
            // the straggler that follows is the one with nobody waiting for
            // it. Consuming the abandoned slot first would instead strand
            // every retry of a key that has timed out once. Whichever answer
            // lands first may be the older one, so the reply says when that
            // is possible and callers that retain values can confirm later.
            let now = ContinuousClock.now
            if let id = replies.firstWaiting(forKey: key) {
                let reply = ReceivedReply(
                    message: message, mayBeStale: replies.mayBeStale(forKey: key, at: now)
                )
                complete(requestID: id, with: reply)
                return
            }

            if replies.consumeOwedReply(forKey: key, at: now) {
                lateReplyCount += 1
                logger.debug(
                    "Dropped a late reply for \(key, privacy: .public) after its request ended"
                )
            }
            return
        }

        eventHistory.record(message, workspaceName: workspace?.displayName ?? currentTarget?.workspaceID)

        if message.address == "/qlab/event/workspace/playhead" {
            handleBroadcastPlayhead(message)
            return
        }

        if message.address.hasPrefix("/update/") {
            handleUpdate(message)
        }
    }

    private func handleBroadcastPlayhead(_ message: OSCMessage) {
        guard message.arguments.count >= 3,
              let cueID = message.arguments[2].stringValue
        else { return }

        guard let listID = workspaceIndex.cueListID(containing: cueID) else {
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

    @ObservationIgnored private var playheadDetailsTask: Task<Void, Never>?

    @ObservationIgnored private var pendingCueDetailIDs = Set<String>()

    /// Invalidates a sleeping debounce without canceling an active request batch.
    @ObservationIgnored private var pendingCueDetailsRevision: UInt64 = 0

    /// Associates each reply with the edit that queued it, so older details cannot win.
    @ObservationIgnored private var cueDetailRevisions: [String: UInt64] = [:]

    @ObservationIgnored private var activeCueDetailIDs = Set<String>()

    private func schedulePlayheadDetailsRefresh() {
        pendingCueDetailIDs.formUnion(visibleCueIDs())
        scheduleCueDetailsRefresh()
    }

    private func scheduleCueDetailsRefresh(for cueID: String) {
        // An edited cue's details are whatever QLab says next, not what was
        // fetched before the edit.
        cuesWithLoadedDetails.remove(cueID)
        cueDetailRevisions[cueID, default: 0] &+= 1
        pendingCueDetailIDs.insert(cueID)
        scheduleCueDetailsRefresh()
    }

    private func scheduleCueDetailsRefresh() {
        guard !pendingCueDetailIDs.isEmpty else { return }
        pendingCueDetailsRevision &+= 1
        guard playheadDetailsTask == nil, let session = connection else { return }

        playheadDetailsTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, self.connection === session {
                let revision = self.pendingCueDetailsRevision
                try? await Task.sleep(for: Self.playheadDetailsDebounce)
                guard !Task.isCancelled, self.connection === session else { break }
                guard revision == self.pendingCueDetailsRevision else { continue }

                let cueIDs = self.pendingCueDetailIDs
                guard !cueIDs.isEmpty else { break }
                self.pendingCueDetailIDs.subtract(cueIDs)
                let revisions = Dictionary(
                    uniqueKeysWithValues: cueIDs.map {
                        ($0, self.cueDetailRevisions[$0, default: 0])
                    }
                )
                await self.refreshCueDetails(for: cueIDs, revisions: revisions, in: session)
            }

            guard self.connection === session else { return }
            self.playheadDetailsTask = nil
            if !self.pendingCueDetailIDs.isEmpty {
                self.scheduleCueDetailsRefresh()
            }
        }
    }

    private func handleUpdate(_ message: OSCMessage) {
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
            guard tail.count >= 2 else {
                scheduleCueListRefresh()
                return
            }

            let cueID = tail[1]
            if !workspaceIndex.contains(cueID) {
                scheduleCueListRefresh()
            } else {
                scheduleCueDetailsRefresh(for: cueID)
            }

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

    @ObservationIgnored private var cueListRefreshTask: Task<Void, Never>?

    private func scheduleCueListRefresh(after delay: Duration = .milliseconds(250)) {
        guard let session = connection else { return }
        cueListRefreshTask?.cancel()
        cueListRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.refreshCueData()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connection === session else { return }
                self.logger.warning(
                    "Debounced cue refresh failed: \(error.localizedDescription, privacy: .public)"
                )
                self.recordError(error)
                self.handleSessionLost(reason: "Cue data could not be refreshed. \(error.localizedDescription)")
            }
        }
    }

    @ObservationIgnored private var cueDataGeneration: UInt64 = 0

    private func requireCueDetailInvalidation() {
        cueDetailInvalidationPending = true
        cueDetailInvalidationGeneration &+= 1
    }

    /// - Parameter invalidatingDetails: refetch every visible cue's details,
    ///   for when updates may have been missed. Retained values stay on
    ///   screen until the new replies land.
    func refreshCueData(invalidatingDetails: Bool = false) async throws {
        guard let session = connection else { return }
        if invalidatingDetails { requireCueDetailInvalidation() }
        let invalidationGeneration = cueDetailInvalidationGeneration
        let shouldInvalidateDetails = cueDetailInvalidationPending
        cueDataGeneration &+= 1
        let generation = cueDataGeneration

        let refreshed = try await refreshCueLists(
            invalidatingDetails: shouldInvalidateDetails, generation: generation, session: session
        )

        guard refreshed, generation == cueDataGeneration,
              connection === session, !Task.isCancelled else { return }
        await refreshPlayheadCueDetails()
        if shouldInvalidateDetails,
           invalidationGeneration == cueDetailInvalidationGeneration {
            cueDetailInvalidationPending = false
        }
    }

    func refreshCueLists(invalidatingDetails: Bool = false) async throws {
        guard let session = connection else { return }
        if invalidatingDetails { requireCueDetailInvalidation() }
        let shouldInvalidateDetails = invalidatingDetails || cueDetailInvalidationPending
        cueDataGeneration &+= 1
        let generation = cueDataGeneration
        _ = try await refreshCueLists(
            invalidatingDetails: shouldInvalidateDetails, generation: generation, session: session
        )
    }

    private func refreshCueLists(
        invalidatingDetails: Bool,
        generation: UInt64,
        session: QLabConnection
    ) async throws -> Bool {
        guard let workspaceID = workspace?.uniqueID, connection === session else { return false }
        let received = try await requestReceivedReply(
            OSCMessage("/workspace/\(workspaceID)/cueLists"), on: session
        )
        guard connection === session else { throw RequestFailure.disconnected }
        try Task.checkCancellation()
        guard generation == cueDataGeneration else { return false }
        guard !received.mayBeStale else {
            scheduleCueListRefresh(after: .seconds(preferences.requestTimeout))
            return false
        }
        let reply = try await validateSessionReply(received.message, as: [Cue].self)
        guard connection === session else { throw RequestFailure.disconnected }
        try Task.checkCancellation()
        guard generation == cueDataGeneration else { return false }
        let refreshed = reply.data ?? []

        // Carry the details already fetched onto the new tree and build the
        // workspace index off the main actor so large cue lists do not block
        // UI rendering. Carrying a value for display is separate from trusting
        // it: after lost events the cues are refetched regardless.
        let loadedBeforePrepare = cuesWithLoadedDetails
        let previous = workspaceIndex.cues(withIDs: loadedBeforePrepare, in: cueLists)
        let previousIndex = workspaceIndex
        let prepared = await prepareRefreshedCueLists(
            refreshed, carrying: previous, reusing: previousIndex
        )
        guard connection === session else { throw RequestFailure.disconnected }
        try Task.checkCancellation()
        guard generation == cueDataGeneration else { return false }

        var nextCueLists = prepared.cueLists
        var carried = prepared.carried
        let newlyLoaded = cuesWithLoadedDetails.subtracting(loadedBeforePrepare)
        if !newlyLoaded.isEmpty {
            let deltaPrevious = workspaceIndex.cues(withIDs: newlyLoaded, in: cueLists)
            carried.formUnion(nextCueLists.carryDetails(from: deltaPrevious))
        }
        if invalidatingDetails {
            for cueID in activeCueDetailIDs {
                cueDetailRevisions[cueID, default: 0] &+= 1
            }
        }
        cuesWithLoadedDetails = invalidatingDetails ? [] : carried

        if cueLists != nextCueLists {
            cueLists = nextCueLists
        }
        workspaceIndex = prepared.index
        if totalCueCount != workspaceIndex.totalCueCount {
            totalCueCount = workspaceIndex.totalCueCount
        }

        let liveListIDs = Set(cueLists.map(\.uniqueID))
        if !playheads.keys.allSatisfy({ liveListIDs.contains($0) }) {
            playheads = playheads.filter { liveListIDs.contains($0.key) }
        }
        playheadRevisions = playheadRevisions.filter { liveListIDs.contains($0.key) }

        reconcileWatchedCueList()
        syncWatchedState()

        await refreshPlayheads()
        return generation == cueDataGeneration && connection === session
    }

    @concurrent
    private nonisolated func prepareRefreshedCueLists(
        _ cueLists: [Cue],
        carrying previous: [String: Cue],
        reusing previousIndex: WorkspaceIndex
    ) async -> (cueLists: [Cue], carried: Set<String>, index: WorkspaceIndex) {
        var refreshed = cueLists
        let carried = refreshed.carryDetails(from: previous)
        let index = WorkspaceIndex(cueLists: refreshed, reusing: previousIndex)
        return (refreshed, carried, index)
    }

    private func reconcileWatchedCueList() {
        guard watchedCueList == nil else { return }

        // Carts have no playhead to watch, so neither a remembered cart nor
        // a leading one is picked.
        let watchable = cueLists.filter { !$0.isCueCart }
        let preferred = preferredCueListID
        watchedCueListID = preferred.flatMap { id in
            watchable.contains { $0.uniqueID == id } ? id : nil
        } ?? watchable.first?.uniqueID

        preferredCueListID = preferred
    }

    private static let maxConcurrentPlayheadRequests = 4

    func refreshPlayheads() async {
        guard let workspaceID = workspace?.uniqueID, let session = connection else { return }
        playheadRefreshGeneration &+= 1
        let refreshGeneration = playheadRefreshGeneration
        let cueGeneration = cueDataGeneration
        // QLab returns an error for a cart's playback position.
        let listIDs = cueLists.filter { !$0.isCueCart }.map(\.uniqueID)
        let revisions = playheadRevisions

        // Results are gathered locally and written back in one go: assigning
        // each one as it lands would invalidate every view watching the
        // playheads once per cue list.
        var fetched: [String: PlayheadState] = [:]
        var receivedStaleReply = false

        let completed = await withBoundedConcurrency(
            over: listIDs,
            limit: Self.maxConcurrentPlayheadRequests,
            while: { !Task.isCancelled && self.connection === session },
            run: { listID in
                await self.fetchPlayhead(
                    forCueListID: listID, workspaceID: workspaceID, session: session
                )
            },
            collect: { result in
                guard let result else { return }
                if result.mayBeStale {
                    receivedStaleReply = true
                } else {
                    fetched[result.listID] = result.state
                }
            }
        )

        guard completed, !Task.isCancelled, connection === session,
              cueGeneration == cueDataGeneration,
              refreshGeneration == playheadRefreshGeneration else { return }
        if receivedStaleReply {
            scheduleCueListRefresh(after: .seconds(preferences.requestTimeout))
        }
        let liveListIDs = Set(cueLists.map(\.uniqueID))
        fetched = fetched.filter {
            liveListIDs.contains($0.key) && playheadRevisions[$0.key] == revisions[$0.key]
        }
        guard !fetched.isEmpty else { return }
        playheads.merge(fetched) { _, latest in latest }
        syncWatchedState()
    }

    private func fetchPlayhead(
        forCueListID listID: String,
        workspaceID: String,
        session: QLabConnection
    ) async -> (listID: String, state: PlayheadState, mayBeStale: Bool)? {
        do {
            let received = try await requestReceivedReply(
                OSCMessage(
                    "/workspace/\(workspaceID)/cue_id/\(listID)/playbackPositionID"
                ),
                on: session
            )
            guard connection === session else { return nil }
            guard !received.mayBeStale else { return (listID, .unset, true) }
            let reply = try await validateSessionReply(received.message, as: String.self)
            guard connection === session else { return nil }

            let state: PlayheadState = if let cueID = reply.data,
                                           !cueID.isEmpty, cueID != "none" {
                .cue(cueID)
            } else {
                .unset
            }
            return (listID, state, received.mayBeStale)
        } catch is CancellationError {
            return nil
        } catch {
            logger.warning(
                """
                playbackPositionID failed for \(listID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return (listID, .unknown(reason: error.localizedDescription), false)
        }
    }

    private func setPlayhead(_ cueID: String?, forCueListID listID: String) {
        // A repeated notification still confirms a position more recently than
        // any snapshot already in flight.
        playheadRevisions[listID, default: 0] &+= 1
        let nextState: PlayheadState = if let cueID, !cueID.isEmpty, cueID != "none" {
            .cue(cueID)
        } else {
            .unset
        }
        guard playheads[listID] != nextState else { return }
        playheads[listID] = nextState
        let nextSummary = makePlayheadSummary(for: nextState)
        if playheadSummaries[listID] != nextSummary {
            playheadSummaries[listID] = nextSummary
        }
        if listID == watchedCueListID {
            syncWatchedState()
        }
    }

    /// The cue list being watched, as it is in the current tree.
    var watchedCueList: Cue? {
        guard let watchedCueListID else { return nil }
        return workspaceIndex.cueList(withID: watchedCueListID, in: cueLists)
    }

    var currentPlayheadCueID: String? {
        watchedPlayhead?.cueID
    }

    func cue(withID cueID: String) -> Cue? {
        workspaceIndex.cue(withID: cueID, in: cueLists)
    }

    func cueListName(containing cueID: String) -> String? {
        guard let listID = workspaceIndex.cueListID(containing: cueID) else { return nil }
        if listID == watchedCueListID {
            return watchedCueListName
        }
        return workspaceIndex.cueList(withID: listID, in: cueLists)?.displayName
    }

    private func syncWatchedState() {
        let nextPlayhead = watchedCueListID.flatMap { playheads[$0] }
        if watchedPlayhead != nextPlayhead {
            watchedPlayhead = nextPlayhead
        }

        let nextGraph = watchedCueListID.flatMap { workspaceIndex.graph(forListID: $0) }
        if watchedGraph?.graphID != nextGraph?.graphID
            || watchedGraph?.numbersVersion != nextGraph?.numbersVersion {
            watchedGraph = nextGraph
        }

        let watchedList = watchedCueListID.flatMap {
            workspaceIndex.cueList(withID: $0, in: cueLists)
        }
        let nextListName = watchedList?.displayName
        if watchedCueListName != nextListName {
            watchedCueListName = nextListName
        }

        let nextIsCart = watchedList?.isCueCart == true
        if isWatchingCueCart != nextIsCart {
            isWatchingCueCart = nextIsCart
        }

        let nextCue: Cue? = if let cueID = nextPlayhead?.cueID {
            nextGraph?.cue(withID: cueID, in: watchedList)
                ?? workspaceIndex.cue(withID: cueID, in: cueLists)
        } else {
            nil
        }
        if playheadCue != nextCue {
            playheadCue = nextCue
        }

        syncSidebarState()
    }

    private func makePlayheadSummary(for state: PlayheadState) -> PlayheadSummary {
        guard case .cue(let cueID) = state else {
            return PlayheadSummary(
                state: state,
                cueDisplayNumber: nil,
                cueDisplayName: nil,
                hasCue: false
            )
        }
        let cue = workspaceIndex.cue(withID: cueID, in: cueLists)
        return PlayheadSummary(
            state: state,
            cueDisplayNumber: cue?.displayNumber,
            cueDisplayName: cue?.displayName,
            hasCue: cue != nil
        )
    }

    private func syncSidebarState() {
        let nextSummaries = cueLists.map(CueListSummary.init(list:))
        if cueListSummaries != nextSummaries {
            cueListSummaries = nextSummaries
        }

        var nextPlayheads: [String: PlayheadSummary] = [:]
        nextPlayheads.reserveCapacity(playheads.count)
        for (listID, state) in playheads {
            nextPlayheads[listID] = makePlayheadSummary(for: state)
        }
        if playheadSummaries != nextPlayheads {
            playheadSummaries = nextPlayheads
        }
    }

    /// The cues on screen: the one standing by, plus the drawer rows either
    /// side of it. Details are fetched for all of them, so an upcoming cue
    /// says what it will do before the playhead ever reaches it.
    private func visibleCueIDs() -> Set<String> {
        guard let cueID = currentPlayheadCueID else { return [] }
        var ids: Set<String> = [cueID]

        if preferences.cueLayout == .list {
            guard let graph = watchedGraph else { return ids }
            // One more either side for the cue waiting just off each band,
            // so it arrives with its details already in hand.
            let radius = CueLayout.listRowRadius + 1
            ids.formUnion(graph.rowsAbove(cueID, count: radius))
            ids.formUnion(graph.rowsBelow(cueID, count: radius))
            return ids
        }

        guard preferences.showsDrawer, let graph = watchedGraph else { return ids }

        let radius = preferences.drawerRowCount
        let neighbourhood = graph.neighbourhood(
            around: cueID, above: radius, below: radius
        )
        ids.formUnion(neighbourhood.above)
        ids.formUnion(neighbourhood.below)
        return ids
    }

    /// Cues whose `/valuesForKeys` reply is already folded into `cueLists`.
    /// Details only change when QLab says so, so a cue is fetched once and
    /// then left alone until it is edited or events are lost. Rebuilt lists
    /// keep the set for cues still present.
    @ObservationIgnored private var cuesWithLoadedDetails = Set<String>()

    func refreshPlayheadCueDetails() async {
        let visible = visibleCueIDs()
        pendingCueDetailIDs.formUnion(visible)
        scheduleCueDetailsRefresh()
        await playheadDetailsTask?.value
    }

    private static let maxConcurrentDetailRequests = 4

    private func refreshCueDetails(
        for cueIDs: Set<String>, revisions: [String: UInt64], in session: QLabConnection
    ) async {
        let wanted = Array(cueIDs.subtracting(cuesWithLoadedDetails))
        guard !wanted.isEmpty, let workspaceID = workspace?.uniqueID else { return }
        guard let keysString = Self.encodedValueKeys else { return }

        activeCueDetailIDs = Set(wanted)
        defer {
            if connection === session {
                activeCueDetailIDs.subtract(wanted)
                for cueID in wanted where !pendingCueDetailIDs.contains(cueID) {
                    cueDetailRevisions.removeValue(forKey: cueID)
                }
            }
        }

        // Gathered first and applied in one pass: writing each reply back as
        // it lands would invalidate every view watching the cue lists once
        // per cue in the drawer.
        var fetched: [FetchedCueDetails] = []

        let completed = await withBoundedConcurrency(
            over: wanted,
            limit: Self.maxConcurrentDetailRequests,
            while: { !Task.isCancelled && self.connection === session },
            run: { cueID in
                await self.fetchCueDetails(
                    for: cueID,
                    workspaceID: workspaceID,
                    keys: keysString,
                    revision: revisions[cueID, default: 0],
                    session: session
                )
            },
            collect: { result in
                if let result { fetched.append(result) }
            }
        )

        guard completed, !Task.isCancelled, connection === session else { return }
        apply(fetched.filter { cueDetailRevisions[$0.cueID, default: 0] == $0.revision })
    }

    private struct FetchedCueDetails {
        let cueID: String
        let values: QLabCueValues
        let revision: UInt64
        /// False when the reply may have answered an earlier, timed-out
        /// request for the same cue, so it is shown but asked for again.
        let isConfirmed: Bool
    }

    private func apply(_ fetched: [FetchedCueDetails]) {
        guard !fetched.isEmpty else { return }

        var updated = cueLists
        var valuesByID: [String: QLabCueValues] = [:]
        for result in fetched {
            valuesByID[result.cueID] = result.values
        }
        let changes = updated.applyValuesAndFindCues(
            valuesByID, using: workspaceIndex
        )

        var unconfirmed = Set<String>()
        for result in fetched where changes.foundCueIDs.contains(result.cueID) {
            if result.isConfirmed {
                cuesWithLoadedDetails.insert(result.cueID)
            } else {
                unconfirmed.insert(result.cueID)
            }
        }
        scheduleUnconfirmedDetailsRefetch(unconfirmed)

        guard !changes.changedCueIDs.isEmpty else { return }
        cueLists = updated

        if !changes.cueNumberUpdates.isEmpty {
            workspaceIndex.applyCueNumberUpdates(changes.cueNumberUpdates)
        }
        syncWatchedState()
    }

    private func fetchCueDetails(
        for cueID: String,
        workspaceID: String,
        keys: String,
        revision: UInt64,
        session: QLabConnection
    ) async -> FetchedCueDetails? {
        do {
            let received = try await requestReceivedReply(
                OSCMessage(
                    "/workspace/\(workspaceID)/cue_id/\(cueID)/valuesForKeys",
                    [.string(keys)]
                ),
                on: session
            )
            guard connection === session else { return nil }
            if received.mayBeStale {
                let reply: QLabReply<QLabCueValues>
                do {
                    reply = try await parse(received.message, as: QLabCueValues.self)
                } catch {
                    try Task.checkCancellation()
                    guard connection === session else { return nil }
                    scheduleUnconfirmedDetailsRefetch([cueID])
                    return nil
                }
                try Task.checkCancellation()
                guard connection === session else { return nil }
                guard reply.status.isSuccess else {
                    scheduleUnconfirmedDetailsRefetch([cueID])
                    return nil
                }
                guard let values = reply.data else {
                    scheduleUnconfirmedDetailsRefetch([cueID])
                    return nil
                }
                return FetchedCueDetails(
                    cueID: cueID, values: values, revision: revision, isConfirmed: false
                )
            }

            let reply = try await validateSessionReply(received.message, as: QLabCueValues.self)
            guard connection === session else { return nil }
            guard let values = reply.data else { return nil }
            return FetchedCueDetails(
                cueID: cueID, values: values, revision: revision, isConfirmed: true
            )
        } catch {
            logger.debug("valuesForKeys failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @ObservationIgnored private var unconfirmedDetailIDs = Set<String>()
    @ObservationIgnored private var unconfirmedDetailsTask: Task<Void, Never>?

    /// Asks again once every answer still owed to a timed-out request has
    /// either arrived or expired, so the retry cannot be ambiguous for the
    /// same reason. One retry is pending at a time.
    private func scheduleUnconfirmedDetailsRefetch(_ cueIDs: Set<String>) {
        guard !cueIDs.isEmpty else { return }
        unconfirmedDetailIDs.formUnion(cueIDs)
        guard unconfirmedDetailsTask == nil else { return }

        unconfirmedDetailsTask = Task { [weak self] in
            guard let timeout = self?.preferences.requestTimeout else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.unconfirmedDetailsTask = nil
            self.pendingCueDetailIDs.formUnion(self.unconfirmedDetailIDs)
            self.unconfirmedDetailIDs.removeAll()
            self.scheduleCueDetailsRefresh()
        }
    }

    private func cancelUnconfirmedDetailsRefetch() {
        unconfirmedDetailsTask?.cancel()
        unconfirmedDetailsTask = nil
        unconfirmedDetailIDs.removeAll()
    }

    /// What every cue-detail refresh asks for, whatever the pills show. A
    /// cue's state only ever reaches the display through `/valuesForKeys`,
    /// so anything Cuety draws unconditionally — in the drawer as much as on
    /// the display — has to be in here or it stays stale until the cue list
    /// is refetched.
    private static let alwaysFetchedKeys = [
        "number", "name", "type", "colorName", "flagged", "armed",
        "continueMode", "isBroken", "isLoaded",
        "notes", "duration", "preWait", "postWait",
    ]

    /// The encoded key list for `/valuesForKeys` is independent of presentation.
    private static let encodedValueKeys: String? = {
        guard let keysJSON = try? JSONEncoder().encode(alwaysFetchedKeys),
              let keysString = String(data: keysJSON, encoding: .utf8)
        else { return nil }
        return keysString
    }()

    private static let degradedThumpThreshold = 3

    private static let lostThumpThreshold = 6

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
        guard let workspaceID = workspace?.uniqueID, let session = connection else { return }

        // Monotonic, so a clock change mid-heartbeat cannot skew the round trip.
        let sentAt = ContinuousClock.now
        do {
            let reply = try await request(
                OSCMessage("/workspace/\(workspaceID)/thump"),
                as: String.self
            )
            guard reply.data == "thump" else {
                throw RequestFailure.handshakeFailed(step: "thump", detail: "Unexpected heartbeat reply.")
            }

            guard connection === session else { return }
            recordThump(roundTrip: TimeInterval(duration: ContinuousClock.now - sentAt))
        } catch {
            guard !Task.isCancelled, connection === session, status.hasLiveData else { return }
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

    private func resetHeartbeatMetrics() {
        heartbeatCount = 0
        lastThumpDate = nil
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
                passcode: target.passcode,
                reconnecting: true
            )
        }
    }

    private func recordError(_ error: any Error) {
        lastErrorDescription = error.localizedDescription
        lastErrorDate = Date()
    }

}
