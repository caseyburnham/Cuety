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
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "QLabClient")
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

    /// What is known about each cue list's playhead, by cue list ID.
    ///
    /// A **missing** entry means Cuety has not asked about that list yet. An
    /// entry says what the answer was, including that the answer was "the
    /// query failed" — see ``PlayheadState``. The old form was
    /// `[String: String]`, where all three of those were one absent key.
    private(set) var playheads: [String: PlayheadState] = [:]

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

    /// Events lost to buffer overflow during this session.
    ///
    /// Surfaced rather than counted quietly. A session that has dropped events
    /// is one where Cuety's model of the show diverged from QLab's, however
    /// briefly, and an operator deciding whether to trust the display deserves
    /// to know that happened.
    private(set) var droppedEventCount = 0

    /// Replies that arrived after the request asking for them had timed out,
    /// and were therefore dropped rather than handed to a later request.
    ///
    /// Worth surfacing rather than merely counting: a session accumulating
    /// these is one where QLab is answering more slowly than the request
    /// timeout allows, which is a setting the operator can actually do
    /// something about. Silence here is what made the misattribution it
    /// prevents so hard to notice.
    private(set) var lateReplyCount = 0

    // MARK: Heartbeat

    private(set) var heartbeatCount = 0
    private(set) var lastThumpDate: Date?

    /// The wait the next `/thump` is scheduled across: when the wait began,
    /// and when the thump is due.
    ///
    /// The pair rather than just the deadline, because a countdown has to know
    /// the span it is counting over — and because deriving the start as
    /// "deadline minus ``Preferences/heartbeatInterval``" would be wrong for
    /// any wait the operator changed the interval during.
    ///
    /// `nil` whenever no heartbeat is scheduled, which is the only honest
    /// answer while there is no session.
    private(set) var nextThumpWindow: Range<Date>?

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

    /// Replies QLab still owes requests that have already timed out, keyed by
    /// correlation key, each with the instant after which it stops being
    /// credible.
    ///
    /// Replies are matched by address in FIFO order, because QLab's reply
    /// envelope carries `workspace_id`, `address`, `status` and `data` and no
    /// request identifier of any kind — there is nowhere to put one, so
    /// correlating by ID is not available at this protocol. That leaves a
    /// hole: a reply that arrives after its request timed out would be handed
    /// to whatever request is next in line for the same address, which is a
    /// stale answer presented as a fresh one.
    ///
    /// So a timeout records what it is still owed. The next reply on that key
    /// is recognised as the abandoned request's and discarded. The common
    /// cause of a timeout is a busy QLab answering late, which this handles
    /// exactly.
    ///
    /// The entries expire, and that bound is the honest part of this. If QLab
    /// truly never answers, the debt is spent on the *next* request instead —
    /// costing one wasted request per genuine timeout, after which the entry
    /// ages out. A session where that keeps happening is a session the
    /// heartbeat's lost-thump threshold is already about to end.
    private var abandonedReplyDeadlines: [String: [ContinuousClock.Instant]] = [:]

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
        // Installed before the stream exists, so no burst can overflow it
        // before anyone is listening for the news.
        await connection.setEventsDroppedHandler { [weak self] lost in
            await self?.handleEventsDropped(lost, on: connection)
        }
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
    /// What Cuety says to QLab on the way out, in order.
    ///
    /// `/forgetMeNot false` is the one that genuinely matters: `true` asks
    /// QLab to *retain* this client's registration past the socket closing, so
    /// leaving it set is how a client accumulates in QLab rather than leaving
    /// cleanly. `/udpKeepAlive false` mirrors the handshake at no cost.
    /// `/disconnect` states the intent outright.
    ///
    /// `/alwaysReply` is deliberately absent. It is per-connection state that
    /// dies with the socket, and `/forgetMeNot false` has already told QLab
    /// not to remember anything about this client — so resetting it would be a
    /// packet sent purely for symmetry with the handshake.
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
        // Cancelling the loop unschedules the thump it was waiting to send, so
        // the deadline goes with it. Leaving it behind would have the inspector
        // counting down to a heartbeat nothing is going to send.
        nextThumpWindow = nil
        overflowRecoveryTask?.cancel()
        overflowRecoveryTask = nil
        // A fresh session starts with a clean escalation history, or a
        // reconnect would arrive already one strike down.
        lastOverflowRecovery = nil
        droppedEventCount = 0

        let connection = self.connection
        // Only worth saying goodbye down a socket that is actually up. After a
        // drop these sends can only fail, and would fill the Activity Log with
        // errors that describe Cuety's own teardown rather than anything that
        // happened to the show.
        if sendDisconnect, status.hasLiveData, let connection {
            // Best effort and deliberately not awaited: QLab is told we're
            // going, but a wedged socket must not block teardown.
            //
            // `Task` inside a `@MainActor` method inherits that isolation, so
            // the log is safe to touch from here.
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
        // A new socket owes nothing for what was sent down the old one.
        abandonedReplyDeadlines.removeAll()

        workspace = nil
        accessLevel = .unspecified
        usedPasscode = false
        invalidateLiveSessionData()
        resetHeartbeatStatistics()
    }

    /// Drops every fact that is only true while the session is live.
    ///
    /// Cue data first: QLab is no longer confirming any of it, and the display
    /// has no business presenting a cue as standing by on the strength of a
    /// reply that arrived before the socket died. Then the two session claims
    /// that describe a *capability* rather than an intention — subscribed, and
    /// connected since — because a dead session has neither.
    ///
    /// Shared by teardown and by an involuntary drop, which have to invalidate
    /// exactly the same things. Only the drop used to skip this, which is how
    /// the pre-drop cue survived the whole reconnect backoff, captioned
    /// "Standing By", with the toolbar hidden in presentation mode and no way
    /// for the operator to tell.
    ///
    /// ``preferredCueListID`` deliberately survives, so a reconnect lands back
    /// on the list the operator was watching. So does ``workspace`` and the
    /// heartbeat history: those describe where Cuety was and means to return,
    /// and the inspector labels them in the past tense already.
    private func invalidateLiveSessionData() {
        isSubscribedToUpdates = false
        connectedSince = nil
        cueLists = []
        playheads = [:]
        watchedCueListID = nil
    }

    /// The session is gone as far as Cuety can tell: stop showing cue data as
    /// though it were live, and start trying to get the session back.
    ///
    /// Keeps ``currentTarget``, which is the whole difference between this and
    /// ``disconnect(sendDisconnect:)``. An involuntary drop is something to
    /// recover from, not a decision to respect.
    ///
    /// Nothing here restores the cue data it discards. That is the reconnect's
    /// job and it already does it: step 7 of the handshake refetches the cue
    /// tree and the playheads, ``refreshCueLists()`` puts the display back on
    /// ``preferredCueListID``, and step 8 refills the detail pills — so a
    /// successful reconnect repopulates the display with no manual refresh.
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

    // MARK: - Event loss

    /// What to do about events the event buffer lost.
    ///
    /// A named decision rather than a condition buried in the method that acts
    /// on it. The choice between these two is the whole policy, and keeping it
    /// separable from the socket it needs is what makes it testable without
    /// faking an overflow.
    nonisolated enum EventLossRecovery: Hashable, Sendable {
        /// Refetch the cue tree, the playheads, and the visible cue's details.
        /// The cheap fix, and the right one for a burst.
        case resynchronize
        /// Rebuild the socket and both subscriptions. For when resynchronizing
        /// has already been tried and did not hold.
        case rebuildSession
    }

    /// How soon a second overflow counts as "resynchronizing did not work".
    ///
    /// One burst is a busy moment; another one straight after it means the
    /// refetch is not keeping up with whatever is arriving, and a subscription
    /// that has quietly lapsed looks exactly like that.
    ///
    /// `nonisolated` so ``recovery(after:at:)`` can read it without the main
    /// actor, which is the point of that method being pure.
    nonisolated static let overflowEscalationWindow: Duration = .seconds(10)

    /// Decides how to recover from event loss, given when the last recovery
    /// ran.
    ///
    /// - Parameters:
    ///   - previous: When event loss was last recovered from in this session,
    ///     or `nil` if this is the first time.
    ///   - now: The current instant.
    ///
    /// Deliberately pure and `nonisolated`: no connection, no clock of its
    /// own, no state to mutate. `/updates` and `/listen/playhead` can lapse
    /// without QLab saying so, and this rule is the only thing standing
    /// between that and a display that quietly stops changing — so it is worth
    /// being able to assert directly rather than inferring from a burst.
    nonisolated static func recovery(
        after previous: ContinuousClock.Instant?,
        at now: ContinuousClock.Instant
    ) -> EventLossRecovery {
        guard let previous, now - previous < overflowEscalationWindow else {
            return .resynchronize
        }
        return .rebuildSession
    }

    /// When the last overflow recovery ran.
    private var lastOverflowRecovery: ContinuousClock.Instant?

    private var overflowRecoveryTask: Task<Void, Never>?

    /// The event buffer overflowed: Cuety's model of the show may have
    /// diverged from QLab's, and it cannot know how.
    ///
    /// Recovery is deliberate rather than hopeful, and which recovery is
    /// ``recovery(after:at:)``'s decision — see ``EventLossRecovery`` for the
    /// two outcomes and why a repeat escalates.
    private func handleEventsDropped(_ lost: Int, on connection: QLabConnection) {
        // A report from a socket that has since been replaced describes a
        // session that no longer exists.
        guard self.connection === connection else { return }
        handleEventLoss(lost)
    }

    /// How long to let a burst settle before recovering from it.
    private static let overflowRecoveryDelay: Duration = .milliseconds(250)

    /// Records event loss against the current session and schedules recovery.
    ///
    /// Internal rather than private, deliberately: this is the seam where the
    /// feature's two halves of coverage meet. That a real overflow is detected
    /// and reported is proved against ``QLabConnection`` with a reader that
    /// genuinely stalls; what happens to the session once a report lands is
    /// proved by calling this and watching the session. Neither half fakes
    /// what the other establishes, and nothing pretends an overflow happened.
    func handleEventLoss(_ lost: Int) {
        guard let connection else { return }

        droppedEventCount += lost
        logger.warning(
            "Event buffer overflowed; \(lost, privacy: .public) event(s) lost"
        )

        // Coalesced, because the burst that caused this is probably still
        // arriving and recovering into it would only overflow again.
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
            // Let go of the handle before reconnecting. `connect` tears the
            // session down, and teardown cancels this task — which is the one
            // currently running, so cancelling it from inside would propagate
            // into the connection attempt it had just started.
            overflowRecoveryTask = nil
            await reconnect()

        case .resynchronize:
            logger.info("Resynchronizing after event loss")
            // The same sequence as everywhere else: what was lost might have
            // been a cue edit, so the details have to be refetched too.
            try? await refreshCueData()
        }
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

        // 7. Fetch the cue tree, every list's playhead, and the detail values
        //    for wherever the playhead already sits — one sequence, the same
        //    one every other trigger uses. See ``refreshCueData()``.
        //
        //    Deliberately all of it before `status = .connected`. This costs
        //    one more round trip on the way in, which on a show network is
        //    milliseconds, and in exchange the display appears complete
        //    instead of appearing and then filling its pills in a beat later.
        //    It also keeps the handshake out of the business of being a
        //    special case: a sequence split around `status` would be one the
        //    generation guard could not see the ends of.
        try await refreshCueData()
        guard self.connection === connection else { throw RequestFailure.disconnected }

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

        // The stream finished. Either the deadline above cancelled the
        // connection, or this task was cancelled and took the loop down with
        // it — and those must not report the same thing. Blaming a cancelled
        // probe on QLab put "QLab did not answer" against a server nobody had
        // finished asking.
        try Task.checkCancellation()
        throw RequestFailure.timedOut(address: message.address)
    }

    private func sendAndAwaitReply(
        _ message: OSCMessage,
        over connection: QLabConnection
    ) async throws -> OSCMessage {
        let id = UUID()
        let key = QLabReplyParser.correlationKey(for: message.address)

        // The cancellation handler is what makes an awaited request abandonable.
        // Without it, cancelling a task that was waiting here stopped nothing:
        // the continuation stayed suspended for the full request timeout, its
        // bookkeeping stayed in `pending`, and the caller — a debounced
        // refresh, a superseded probe — went on waiting for an answer nobody
        // wanted any more.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already cancelled before the continuation existed, so
                // `onCancel` has run and found nothing to fail. Resume here or
                // nothing ever will.
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

                    // Cancelled, failed, or answered while the send was in
                    // flight. Arming a deadline for a request that is no
                    // longer pending leaks a task and an entry in
                    // `timeoutTasks` for the length of the timeout.
                    guard self.pending[id] != nil else { return }

                    // Every request carries a deadline, so no call site can
                    // hang forever waiting on a QLab that has stopped
                    // answering.
                    self.timeoutTasks[id] = Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(for: .seconds(self.preferences.requestTimeout))
                        guard !Task.isCancelled else { return }
                        self.timeOut(requestID: id, address: message.address)
                    }
                }
            }
        } onCancel: {
            // `onCancel` runs on whichever thread cancelled, so this has to
            // hop. Both orderings are safe: if the hop wins, `fail` finds
            // nothing and the guard above throws instead; if the body wins,
            // this finds the installed continuation and fails it.
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

    /// Gives up on a request, and remembers that QLab may yet answer it.
    ///
    /// Distinct from ``fail(requestID:with:)`` because a timeout is the one
    /// failure whose reply might still be on its way — see
    /// ``abandonedReplyDeadlines`` for why that has to be recorded rather than
    /// forgotten.
    private func timeOut(requestID id: UUID, address: String) {
        guard let request = removePending(id) else { return }
        abandonedReplyDeadlines[request.correlationKey, default: []]
            .append(ContinuousClock.now + .seconds(preferences.requestTimeout))
        request.continuation.resume(throwing: RequestFailure.timedOut(address: address))
    }

    /// Whether an incoming reply on `key` belongs to a request that already
    /// timed out, and so must not be given to whatever is waiting now.
    ///
    /// Consuming is the point: each abandoned request accounts for exactly one
    /// late reply. Expired entries are pruned on the way past, so a QLab that
    /// went silent rather than slow does not leave this swallowing replies
    /// indefinitely.
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
        // FIFO, matching how replies are correlated: the oldest abandoned
        // request is the one this reply answers.
        deadlines.removeFirst()
        return true
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
    ///
    /// **Nothing reached from here may await a request.** This runs on the
    /// session's one event consumer, and replies arrive as events on the same
    /// stream — so an `await` on a round trip here waits for something that
    /// cannot be delivered until this returns. Work that needs the network
    /// gets scheduled instead: see ``schedulePlayheadDetailsRefresh()`` and
    /// ``scheduleCueListRefresh()``, both of which hand off to a task and
    /// return immediately.
    private func route(_ message: OSCMessage) async {
        // Replies first: match against the oldest in-flight request for the
        // address the reply echoes.
        if QLabReplyParser.isReply(message) {
            guard let address = QLabReplyParser.correlationAddress(of: message) else { return }
            let key = QLabReplyParser.correlationKey(for: address)

            // A reply owed to a request that already timed out. It answers
            // that request, not whichever one happens to be waiting on this
            // address now, so it is dropped rather than misattributed.
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

        // Broadcast identifies the cue but not its cue list, so the list has
        // to be found in the tree.
        //
        // There is no fallback to the watched list. Assigning an unrecognised
        // cue to whatever the operator happens to be watching puts a cue on
        // screen under a list that may well not contain it — a guess rendered
        // as a fact. The realistic cause is a cue added since the last tree
        // fetch, so ask for the tree again and let the cue-data sequence place
        // it properly.
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

    /// How long to let the playhead settle before asking about the cue it
    /// landed on.
    ///
    /// Short enough to read as immediate, long enough that walking a stack
    /// with GO does not put a round trip on the wire per press.
    private static let playheadDetailsDebounce: Duration = .milliseconds(60)

    private var playheadDetailsTask: Task<Void, Never>?

    /// Refetches the detail values for the cue at the playhead, coalescing a
    /// run of moves into one request for the cue that ends up standing by.
    ///
    /// **Never await network work from inside event handling.** Replies arrive
    /// as events on the stream that ``route(_:)`` is itself being driven by,
    /// and that stream has exactly one consumer — so awaiting a request there
    /// parks the consumer until the reply it wants can be read, which it never
    /// can. It resolves as a request timeout every time, and on a fast cue
    /// sequence the timeouts stack until the display is seconds behind the
    /// show. That is precisely what a direct `await` here did.
    ///
    /// Coalescing matters independently: the `/updates` and Show Control
    /// Broadcast feeds both report a playhead move, so a single GO can arrive
    /// twice, and only the cue that ends up standing by is worth asking about.
    private func schedulePlayheadDetailsRefresh() {
        playheadDetailsTask?.cancel()
        playheadDetailsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.playheadDetailsDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.refreshPlayheadCueDetails()
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
            scheduleCueListRefresh()

        case "disconnect":
            logger.info("QLab asked us to disconnect")
            handleWorkspaceClosed()

        case "cue_id":
            // QLab uses this form for cue edits, renames, and newly inserted
            // cues. Refresh the list model regardless of whether the changed
            // cue is currently on the playhead.
            scheduleCueListRefresh()

        case "cueList":
            if tail.count >= 3, tail[2] == "playbackPosition" {
                let listID = tail[1]
                setPlayhead(message.arguments.first?.stringValue, forCueListID: listID)
                if watchedCueListID == nil { watchedCueListID = listID }

                // The tree has not changed, so this needs details only — but
                // it does need them. A playhead moving on a QLab that reports
                // it this way used to leave the pills describing the previous
                // cue.
                //
                // Scheduled, never awaited. See
                // ``schedulePlayheadDetailsRefresh()``.
                schedulePlayheadDetailsRefresh()
            }

        default:
            break
        }
    }

    /// Coalesces bursts of workspace-level updates into one refetch.
    private var cueListRefreshTask: Task<Void, Never>?

    /// Schedules a full cue-data refresh, coalescing a burst of updates into
    /// one.
    ///
    /// Not `async`, deliberately: it starts a task and returns, so awaiting it
    /// only ever meant awaiting the scheduling. Worse, being `async` made it
    /// *look* like something event handling should await — and the caller that
    /// took that hint and awaited the work itself deadlocked the session. See
    /// ``route(_:)``.
    private func scheduleCueListRefresh() {
        cueListRefreshTask?.cancel()
        cueListRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // The whole sequence, not just the tree. This path is what QLab
            // pushes on every cue edit, and stopping at the tree is what left
            // the detail pills blank after one.
            try? await self.refreshCueData()
        }
    }

    // MARK: - Cue data

    /// Which cue-data sequence is current, so a superseded one cannot apply
    /// its details on top of a newer tree.
    private var cueDataGeneration = 0

    /// The one order cue data is fetched in: the cue tree, then every list's
    /// playhead, then the detail values for the cue actually on screen.
    ///
    /// Every trigger goes through here — the handshake, a `/updates` push, and
    /// overflow recovery — because the three steps are not independent.
    /// `/cueLists` carries the tree and nothing else: duration, pre- and
    /// post-wait, notes and continue mode come from `valuesForKeys` for one
    /// cue at a time. A path that refetched the tree and stopped therefore
    /// replaced populated cues with bare ones and blanked the detail pills
    /// until something unrelated happened to ask again — which is exactly what
    /// editing a cue in QLab used to do.
    func refreshCueData() async throws {
        cueDataGeneration += 1
        let generation = cueDataGeneration

        try await refreshCueLists()

        // A newer sequence started while the tree was in flight. Its tree is
        // the current one, and its details are the ones that belong on top.
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

        // Carry the detail values for the cue on screen across the
        // replacement, then let ``refreshCueData()`` refetch them.
        //
        // Both halves matter. Without the refetch the pills would keep showing
        // whatever was true before the edit, which on a cue the operator just
        // changed is the worst kind of wrong. Without the carry-forward they
        // would blank for a round trip every time any cue in the workspace
        // changed — a visible flicker on a stage display, caused by an edit
        // that may have had nothing to do with the cue being shown.
        //
        // Only the playhead cue is carried because only the playhead cue ever
        // has details: they are fetched one cue at a time, for the one on
        // screen.
        if let cueID = currentPlayheadCueID,
           let previous = cueLists.firstCue(withID: cueID) {
            refreshed.applyValues(previous.detailValues, toCueWithID: cueID)
        }

        cueLists = refreshed

        // Playheads for lists that no longer exist are not facts about
        // anything. Keeping them would let a deleted list's last known cue
        // linger in the inspector's counts and in the sidebar.
        let liveListIDs = Set(cueLists.map(\.uniqueID))
        playheads = playheads.filter { liveListIDs.contains($0.key) }

        reconcileWatchedCueList()

        // Cue lists and playheads are refreshed together on purpose. The push
        // feed only reports a playhead when it *moves*, so for a list we have
        // just learned about nothing else would ever fill this in.
        await refreshPlayheads()
    }

    /// Keeps ``watchedCueListID`` pointing at a cue list that exists.
    ///
    /// Run on **every** change to the collection, not only when nothing is
    /// selected. Deleting the watched list in QLab used to leave the selection
    /// pointing at it: nothing matched, so `playheadCue` found nothing, and
    /// the display reported that the playhead was unset — a confident
    /// statement about a cue list that no longer existed.
    private func reconcileWatchedCueList() {
        if let watchedCueListID,
           cueLists.contains(where: { $0.uniqueID == watchedCueListID }) {
            return
        }

        // Back to the list the operator was on, if this workspace still has
        // it. Falling straight through to the first list would mean a dropped
        // connection silently changed what the display follows.
        let preferred = preferredCueListID
        watchedCueListID = preferred.flatMap { id in
            cueLists.contains { $0.uniqueID == id } ? id : nil
        } ?? cueLists.first?.uniqueID

        // Landing somewhere by fallback is not the operator choosing it, so
        // keep remembering what they actually chose. Otherwise deleting
        // "Effects" would rewrite their preference to "Main", and bringing
        // "Effects" back would not return the display to it.
        preferredCueListID = preferred
    }

    /// Asks every cue list where its playhead currently sits.
    ///
    /// Without this, a freshly connected workspace shows every list as having
    /// an unset playhead until someone advances a cue in QLab — the subscription
    /// from step 4 of the handshake reports *changes*, not current state.
    func refreshPlayheads() async {
        guard let workspaceID = workspace?.uniqueID else { return }
        // The session this loop belongs to. `cueLists` is snapshotted by the
        // `for` below, so without this check a loop that outlived its session
        // would work through every list of a show that is no longer on screen.
        let session = connection

        for list in cueLists {
            // Checked before each request, not once at the top. A superseded
            // debounced refresh and a torn-down session both have to stop
            // here; the mutation side is already covered, because `request`
            // re-checks the connection after its await and refuses to hand
            // back a reply from a session that has ended.
            guard !Task.isCancelled, connection === session else { return }

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
                    playheads[list.uniqueID] = .unknown(
                        reason: "QLab answered \(reply.status) for this cue list."
                    )
                    continue
                }

                setPlayhead(reply.data, forCueListID: list.uniqueID)
            } catch is CancellationError {
                // Cuety stopped asking. Nothing went wrong with the show, and
                // logging a warning per remaining list would bury the ones
                // that mean something. Deliberately leaves the existing state
                // alone: abandoning a question is not learning an answer.
                return
            } catch {
                // One list that won't answer must not stop the others: a cart,
                // or a list QLab declines for, shouldn't blank the display.
                //
                // Recorded as unknown rather than skipped. Leaving no entry is
                // what let a failed query read as "this list has no cue
                // standing by" — a confident statement about a list Cuety
                // could not reach.
                logger.warning(
                    """
                    playbackPositionID failed for \(list.uniqueID, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                playheads[list.uniqueID] = .unknown(reason: describe(error))
            }
        }
    }

    /// Records a playhead, treating QLab's several spellings of "unset" alike.
    ///
    /// An absent argument, an empty string, and the literal `none` all mean the
    /// same thing, and it is a real state rather than a missing value — so it
    /// is stored as ``PlayheadState/unset`` rather than by removing the key.
    /// Removing it would say "never asked", which is a different claim and the
    /// one the display used to make.
    private func setPlayhead(_ cueID: String?, forCueListID listID: String) {
        guard let cueID, !cueID.isEmpty, cueID != "none" else {
            playheads[listID] = .unset
            return
        }
        playheads[listID] = .cue(cueID)
    }

    /// What is known about the watched cue list's playhead.
    ///
    /// `nil` when no list is being watched, or when this one has not been
    /// asked about yet — which the display words differently from either an
    /// unset playhead or a failed query.
    var watchedPlayhead: PlayheadState? {
        guard let watchedCueListID else { return nil }
        return playheads[watchedCueListID]
    }

    /// The cue ID standing by in the watched cue list, if one is known to be.
    var currentPlayheadCueID: String? {
        watchedPlayhead?.cueID
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
                // Recorded before the sleep, not after it: the inspector
                // counts down to this, and a deadline published only once the
                // wait was over would be a deadline that had already passed.
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
        nextThumpWindow = nil
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
