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
    var watchedCueListID: String? {
        didSet {
            if let watchedCueListID { preferredCueListID = watchedCueListID }
        }
    }

    // MARK: Session facts, for the inspector

    private(set) var connectedSince: Date?
    private(set) var usedPasscode = false
    /// The permission tier QLab granted this session.
    private(set) var accessLevel: QLabAccessLevel = .unspecified
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

    var onPasscodeRequired: ((Bool) -> Void)?

    /// Why a session ended in a way Cuety is not going to try to undo.
    enum SessionEnd: Hashable, Sendable {
        /// The workspace is no longer open in QLab.
        case workspaceClosed
    }

    /// Called when a session ends for good, so the app can bring the rest of
    /// its state — the sidebar's workspace list, the current selection — back
    /// in line with what QLab actually has open.
    var onSessionEnded: ((SessionEnd) -> Void)?

    /// Whether there is a session to end: live, mid-connect, or waiting out a
    /// reconnect backoff.
    ///
    /// Deliberately broader than ``ConnectionStatus/hasLiveData``. A reconnect
    /// loop has no data to show but very much needs a way for the operator to
    /// call it off, and offering them "Connect" while Cuety is already trying
    /// to connect is not that.
    var isSessionActive: Bool { currentTarget != nil }

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

    /// The cue list the operator last chose, remembered independently of any
    /// one session.
    ///
    /// Teardown clears ``watchedCueListID`` along with the rest of the
    /// session's derived state, and the handshake then falls back to whichever
    /// list happens to be first. Without this, a dropped connection on a
    /// multi-list show would quietly move the display off the list the
    /// operator was watching — and they would find out during the show.
    ///
    /// Never cleared: reconnecting to the same workspace should land back on
    /// the same list, and an ID from a different workspace simply won't match.
    private var preferredCueListID: String?

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
        try await probe.waitUntilReady(timeout: preferences.requestTimeout)

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
        // Tear down the socket but not the intent. `disconnect()` is for the
        // operator changing their mind, and would throw away the very things
        // an automatic reconnect depends on: the target it is heading for and
        // the cue list it should land on.
        tearDownSession(sendDisconnect: true)
        reconnectTask?.cancel()
        reconnectTask = nil

        currentTarget = (server, workspaceID, passcode)
        status = .connecting

        let connection = QLabConnection(endpoint: server.endpoint)
        self.connection = connection
        let stream = await connection.start()

        do {
            try await connection.waitUntilReady(timeout: preferences.requestTimeout)
            guard self.connection === connection else { return }
            // Once ready, one consumer owns all session events.
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

    /// Tears the session down and builds it again against the same workspace.
    ///
    /// Distinct from refetching cue data, which only asks QLab to restate what
    /// it already believes. This re-does the parts that asking cannot fix: the
    /// socket, and the `/updates` and `/listen/playhead` subscriptions, either
    /// of which can lapse without QLab saying so — leaving a session that looks
    /// healthy and reports a playhead that stopped moving hours ago.
    ///
    /// The display briefly shows `connecting` while this runs. That is left
    /// visible on purpose: the operator asked for the connection to be rebuilt,
    /// and a rebuild that gave no sign of happening would be worse than a
    /// moment of honest status.
    ///
    /// The watched cue list survives, via ``preferredCueListID``.
    func reconnect() async {
        guard let target = currentTarget else { return }
        await connect(
            to: target.server,
            workspaceID: target.workspaceID,
            passcode: target.passcode
        )
    }

    /// Tears the session down for good, optionally telling QLab first.
    ///
    /// This is the operator saying "stop", so it drops the reconnect schedule
    /// too — nothing should quietly re-establish what they just closed.
    func disconnect(sendDisconnect: Bool = true) {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentTarget = nil
        backoffAttempt = 0

        tearDownSession(sendDisconnect: sendDisconnect)

        status = .offline
    }

    /// Closes the socket and clears everything derived from the session,
    /// leaving ``currentTarget``, the backoff, and ``preferredCueListID``
    /// alone.
    ///
    /// Split from ``disconnect(sendDisconnect:)`` because a dropped session
    /// and a deliberate one differ in exactly that respect: after a drop Cuety
    /// still knows where it was and means to go back, and conflating the two
    /// is what made a reconnect forget which workspace it was reconnecting to.
    ///
    /// Leaves `status` untouched. Every caller ends up somewhere different —
    /// `connecting`, `needsPasscode`, `workspaceClosed`, `offline` — and each
    /// says so itself rather than having this guess.
    private func tearDownSession(sendDisconnect: Bool) {
        cueListRefreshTask?.cancel()
        cueListRefreshTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let connection = self.connection
        // Only worth saying goodbye down a socket that is actually up. After a
        // drop these three sends can only fail, and would fill the Activity
        // Log with errors that describe Cuety's own teardown rather than
        // anything that happened to the show.
        if sendDisconnect, status.hasLiveData, let connection {
            // Best effort and deliberately not awaited: QLab is told we're
            // going, but a wedged socket must not block teardown.
            Task {
                _ = try? await connection.send(OSCMessage("/forgetMeNot", [.false]))
                _ = try? await connection.send(OSCMessage("/udpKeepAlive", [.false]))
                _ = try? await connection.send(OSCMessage("/disconnect"))
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
        accessLevel = .unspecified
        usedPasscode = false
        cueLists = []
        playheads = [:]
        watchedCueListID = nil
        resetHeartbeatStatistics()
    }

    /// The session is gone as far as Cuety can tell: stop showing cue data as
    /// though it were live, and start trying to get the session back.
    ///
    /// Keeps ``currentTarget``, which is the whole difference between this and
    /// ``disconnect(sendDisconnect:)``. An involuntary drop is something to
    /// recover from, not a decision to respect.
    private func handleSessionLost(reason: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        cueListRefreshTask?.cancel()
        cueListRefreshTask = nil
        failAllPendingRequests(with: RequestFailure.disconnected)

        status = .failed(reason: reason)
        scheduleReconnect()
    }

    /// Ends the session because the workspace itself has gone.
    ///
    /// Terminal on purpose, and the one drop that gets no reconnect: QLab is
    /// answering perfectly well, it just doesn't have this workspace any more,
    /// so retrying would only ask the same question again. The operator has to
    /// choose something else, so say so plainly and let the sidebar catch up.
    private func handleWorkspaceClosed() {
        disconnect(sendDisconnect: false)
        status = .workspaceClosed
        onSessionEnded?(.workspaceClosed)
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
        let connectData = connectReply.data ?? ""

        if connectReply.status.isSuccess,
           let level = QLabAccessLevel(connectReplyData: connectData) {
            // Covers both `ok` and `ok:<level>`. Matching only a bare `ok`
            // here rejected every QLab 5 workspace that has a passcode set,
            // because those answer with the granted tier instead.
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

        // 3. Keep this client registered with QLab for the lifetime of the
        //    session. These are client-level commands, not workspace methods.
        try await sendWithoutReply(OSCMessage("/forgetMeNot", [.true]))
        try await sendWithoutReply(OSCMessage("/udpKeepAlive", [.true]))

        // 4. Ask QLab to reply to everything. This makes correlation reliable
        //    for commands that do not otherwise produce a natural reply.
        _ = try await request(
            OSCMessage("/alwaysReply", [.true]),
            as: QLabEmptyPayload.self
        )

        // 5. Subscribe to workspace updates so cue-list changes (including
        //    newly added cues) trigger a refresh.
        let updatesReply = try await request(
            OSCMessage("/updates", [.true]),
            as: QLabEmptyPayload.self
        )

        // 6. Subscribe to Show Control Broadcast playhead events. The two
        //    feeds are complementary: /updates describes model changes, while
        //    /listen/playhead reports the cue currently standing by.
        let playheadReply = try await request(
            OSCMessage("/listen/playhead"),
            as: QLabEmptyPayload.self
        )
        isSubscribedToUpdates = updatesReply.status.isSuccess
            && playheadReply.status.isSuccess

        // 7. Fetch the cue lists, and with them the current playheads.
        try await refreshCueLists()
        guard self.connection === connection else { throw RequestFailure.disconnected }

        connectedSince = Date()
        backoffAttempt = 0
        status = .connected
        startHeartbeat()

        // 8. Fill in the detail pills for wherever the playhead already is,
        //    rather than leaving them blank until the next cue.
        await refreshPlayheadCueDetails()

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

        case RequestFailure.workspaceUnavailable(let id):
            // QLab answered, and did not list this workspace. Retrying would
            // only ask the same question again, so end the session and say
            // what actually happened rather than blaming the network.
            logger.info("Workspace \(id, privacy: .public) is no longer open")
            handleWorkspaceClosed()

        default:
            status = .failed(reason: describe(error))
            scheduleReconnect()
        }
    }

    // MARK: - Requests

    private struct PendingRequest {
        let id: UUID
        /// The ``QLabReplyParser/correlationKey(for:)`` form, not the address as
        /// sent — see that method for why the two differ.
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

    /// Sends a client-level command whose transport delivery is all Cuety
    /// needs. QLab does not reliably emit a correlated reply for keep-alive
    /// registration, so these must not block the handshake waiting for one.
    private func sendWithoutReply(_ message: OSCMessage) async throws {
        guard let connection else { throw RequestFailure.disconnected }
        let byteCount = try await connection.send(message)
        log.record(OSCEvent(message: message, direction: .outbound, byteCount: byteCount))
    }

    /// Sends a message and awaits its typed reply.
    @discardableResult
    private func request<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) async throws -> QLabReply<Payload> {
        guard let connection else { throw RequestFailure.disconnected }
        let replyMessage = try await sendAndAwaitReply(message, over: connection)
        guard self.connection === connection else { throw RequestFailure.disconnected }
        return try validateSessionReply(replyMessage, as: payloadType)
    }

    /// Check authorization before decoding a payload: denied replies may carry
    /// an error string where a successful request would return cue arrays.
    func validateSessionReply<Payload: Decodable & Sendable>(
        _ message: OSCMessage, as payloadType: Payload.Type
    ) throws -> QLabReply<Payload> {
        let envelope = try QLabReplyParser.parse(message, as: QLabEmptyPayload.self)
        if envelope.status == .denied {
            requirePasscode()
            throw RequestFailure.passcodeRequired
        }
        guard envelope.status.isSuccess else {
            throw RequestFailure.handshakeFailed(
                step: envelope.address, detail: "QLab returned \(envelope.status)."
            )
        }
        return try QLabReplyParser.parse(message, as: payloadType)
    }

    private func requirePasscode() {
        // Several requests can be in flight when QLab starts refusing them,
        // and every one of them comes back denied. Only the first is news:
        // running this again would rebuild the sheet and — because the target
        // has already been cleared by then — quietly downgrade "that passcode
        // was rejected" to "a passcode is required", losing the one detail
        // that tells the operator they typed it wrong.
        if case .needsPasscode = status { return }

        let rejected = currentTarget?.passcode != nil
        disconnect(sendDisconnect: false)
        status = .needsPasscode(rejected: rejected)
        recordError(rejected ? RequestFailure.passcodeRejected : RequestFailure.passcodeRequired)
        onPasscodeRequired?(rejected)
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
        // until the matching reply shows up.
        //
        // Cancelling the connection is what enforces the deadline: that
        // finishes the stream, which ends the loop below. A `Date` compared
        // inside the loop cannot do the job, because a QLab that has stopped
        // answering sends nothing to compare it on — the loop simply parks,
        // and with it the sidebar refresh that is waiting on this.
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
        let key = QLabReplyParser.correlationKey(for: message.address)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(
                id: id, correlationKey: key, continuation: continuation
            )
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
            //
            // Only meaningful once the session is up. Before that, `.waiting`
            // belongs to a connection attempt that already has a deadline of
            // its own, and the event can be buffered long enough to arrive
            // after the handshake succeeded — which would leave a perfectly
            // healthy session claiming to be degraded.
            if status.hasLiveData {
                status = .degraded(reason: "Waiting for the network: \(error.localizedDescription)")
            }

        case .failed(let error):
            recordError(error)
            if status.hasLiveData {
                handleSessionLost(reason: error.localizedDescription)
            } else {
                // Mid-handshake. `connect` is awaiting these requests and
                // reports the failure itself, so recovering here as well would
                // schedule two reconnects and double-count the backoff.
                failAllPendingRequests(with: error)
            }

        case .cancelled:
            // Once live, this is the shape a QLab quit usually takes: it
            // closes the socket on its way out.
            if status.hasLiveData {
                handleSessionLost(reason: "QLab closed the connection.")
            } else {
                failAllPendingRequests(with: RequestFailure.disconnected)
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
               let id = pendingByAddress[QLabReplyParser.correlationKey(for: address)]?.first {
                complete(requestID: id, with: message)
            }
            return
        }

        // Show Control Broadcast messages are ordinary OSC messages rather
        // than JSON-wrapped replies.
        if message.address == "/qlab/event/workspace/playhead" {
            handleBroadcastPlayhead(message)
            return
        }

        // Retain support for legacy workspace updates when talking to older
        // QLab versions, even though new sessions use /listen/playhead.
        if message.address.hasPrefix("/update/") {
            await handleUpdate(message)
        }
    }

    private func handleBroadcastPlayhead(_ message: OSCMessage) {
        // /listen/playhead sends: number, name, uniqueID, type.
        guard message.arguments.count >= 3,
              let cueID = message.arguments[2].stringValue
        else { return }

        // Broadcast identifies the cue, but not its cue list. Prefer the list
        // containing that cue; fall back to the list the operator is watching.
        let listID = cueLists.first {
            CueGraph(cueList: $0).cue(withID: cueID) != nil
        }?.uniqueID ?? watchedCueListID

        guard let listID else { return }
        setPlayhead(cueID, forCueListID: listID)
        if watchedCueListID == nil {
            watchedCueListID = listID
        }

        Task { [weak self] in
            await self?.refreshPlayheadCueDetails()
        }
    }

    // MARK: - Push updates

    private func handleUpdate(_ message: OSCMessage) async {
        let components = message.addressComponents
        // Shapes, all prefixed by ["update", "workspace", <id>]:
        //   …                                       → reload cue lists
        //   … + ["cue_id", <cueID>]                 → reload cue lists
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
            handleWorkspaceClosed()

        case "cue_id":
            // QLab uses this form for cue edits, renames, and newly inserted
            // cues. Refresh the list model regardless of whether the changed
            // cue is currently on the playhead.
            await debouncedCueListRefresh()

        case "cueList":
            if tail.count >= 3, tail[2] == "playbackPosition" {
                let listID = tail[1]
                setPlayhead(message.arguments.first?.stringValue, forCueListID: listID)
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
    // MARK: - Cue data

    func refreshCueLists() async throws {
        guard let workspaceID = workspace?.uniqueID else { return }
        let reply = try await request(
            OSCMessage("/workspace/\(workspaceID)/cueLists"),
            as: [Cue].self
        )
        cueLists = reply.data ?? []

        if watchedCueListID == nil {
            // Back to the list the operator was on, if this workspace still
            // has it. Falling straight through to the first list would mean a
            // dropped connection silently changed what the display follows.
            watchedCueListID = preferredCueListID.flatMap { id in
                cueLists.contains { $0.uniqueID == id } ? id : nil
            } ?? cueLists.first?.uniqueID
        }

        // Cue lists and playheads are refreshed together on purpose. The push
        // feed only reports a playhead when it *moves*, so for a list we have
        // just learned about nothing else would ever fill this in.
        await refreshPlayheads()
    }

    /// Asks every cue list where its playhead currently sits.
    ///
    /// Without this, a freshly connected workspace shows every list as having
    /// an unset playhead until someone advances a cue in QLab — the subscription
    /// from step 4 of the handshake reports *changes*, not current state.
    func refreshPlayheads() async {
        guard let workspaceID = workspace?.uniqueID else { return }

        for list in cueLists {
            do {
                // `playbackPositionID`, not `…Id`. OSC addresses are
                // case-sensitive and QLab 5 capitalises the `ID` — the QLab 4
                // dictionary spelled it `playbackPositionId`, so the wrong
                // spelling looks plausible and fails as a silent empty reply
                // rather than as an obvious error.
                let reply = try await request(
                    OSCMessage(
                        "/workspace/\(workspaceID)/cue_id/\(list.uniqueID)/playbackPositionID"
                    ),
                    as: String.self
                )

                // A non-success status is a *failed query*, not an unset
                // playhead. Conflating the two is what let the misspelled
                // address above masquerade as "this list has no playhead".
                guard reply.status.isSuccess else {
                    logger.warning(
                        """
                        playbackPositionID for \(list.uniqueID, privacy: .public) \
                        answered \(String(describing: reply.status), privacy: .public)
                        """
                    )
                    continue
                }

                setPlayhead(reply.data, forCueListID: list.uniqueID)
            } catch {
                // One list that won't answer must not stop the others: a cart,
                // or a list QLab declines for, shouldn't blank the display.
                logger.warning(
                    """
                    playbackPositionID failed for \(list.uniqueID, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        }
    }

    /// Records a playhead, treating QLab's several spellings of "unset" alike.
    ///
    /// An absent argument, an empty string, and the literal `none` all mean the
    /// same thing, and it is a real state rather than a missing value — the
    /// display has an empty state for it.
    private func setPlayhead(_ cueID: String?, forCueListID listID: String) {
        guard let cueID, !cueID.isEmpty, cueID != "none" else {
            playheads.removeValue(forKey: listID)
            return
        }
        playheads[listID] = cueID
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

    /// Missed heartbeats worth calling the connection degraded. One on a busy
    /// show network is noise; three in a row is a real signal, and matches the
    /// TCP keepalive count.
    private static let degradedThumpThreshold = 3

    /// Missed heartbeats worth calling the session dead.
    ///
    /// The backstop for a QLab that still answers TCP but no longer answers
    /// *for this workspace* — a workspace closed without the push
    /// notification arriving, or a passcode added mid-show that turns every
    /// reply into a refusal. Without an upper bound the session sat in
    /// `degraded` indefinitely, showing a playhead that had stopped moving
    /// and calling it live data.
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

        // Say so while the backoff runs. A static red glyph for the next
        // thirty seconds reads as "Cuety has given up", which is the opposite
        // of what is happening — and it gives the operator nothing to decide
        // whether to intervene on.
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
            // Let go of the handle before connecting. `connect` cancels the
            // pending reconnect, and this task *is* that reconnect — cancelling
            // it from inside would propagate into the connection attempt it
            // just started.
            self.reconnectTask = nil
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

    /// Turns an error into something an operator can read.
    ///
    /// Cuety's own error types word their `description` for the inspector, so
    /// they are preferred when present. Anything else, `NWError` included,
    /// reads better through `localizedDescription` — a bare `CustomStringConvertible`
    /// cast is no good here, since bridged `NSError`s satisfy it and describe
    /// themselves as `Error Domain=… Code=…`.
    private func describe(_ error: any Error) -> String {
        if let described = error as? any OperatorReadableError {
            return described.description
        }
        return error.localizedDescription
    }
}

// MARK: - Operator-readable errors

/// An error whose `description` is prose written for the person running the
/// show, not a debugging dump.
///
/// ``QLabClient/describe(_:)`` surfaces that wording in the connection
/// inspector and the Activity Log. Conform new Cuety error types below;
/// without the conformance they fall back to `localizedDescription`, which for
/// a Swift error type is the unhelpful "The operation couldn't be completed."
nonisolated protocol OperatorReadableError: Error, CustomStringConvertible {}

nonisolated extension OSCDecodingError: OperatorReadableError {}
nonisolated extension SLIPFramingError: OperatorReadableError {}
extension PasscodeStore.Failure: OperatorReadableError {}
nonisolated extension QLabReplyParser.Failure: OperatorReadableError {}
extension QLabConnection.SendFailure: OperatorReadableError {}
extension QLabClient.RequestFailure: OperatorReadableError {}
