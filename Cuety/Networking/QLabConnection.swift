import Foundation
import Network
import os
import ShowControlCore

/// Tracks whether a send has begun so cancellation can distinguish an unsent
/// request from one that may already be in flight.
final class QLabSendState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var hasStarted = false
    nonisolated(unsafe) private var wasCancelled = false

    nonisolated func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !wasCancelled else { return false }
        hasStarted = true
        return true
    }

    nonisolated func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        wasCancelled = true
        return hasStarted
    }
}

/// `NWConnection` callbacks arrive on its queue; the actor isolates connection state.
actor QLabConnection {
    enum Event: Sendable {
        case stateChanged(NWConnection.State)
        case pathChanged(isViable: Bool)
        case received(OSCMessage, byteCount: Int)
        case receiveFailed(OSCDecodingError, byteCount: Int)
    }

    private let endpoint: NWEndpoint
    private let logger = Logger(category: "QLabConnection")

    /// QLab replies can carry a whole workspace of JSON, so a packet may use
    /// the full SLIP frame; the remaining budgets keep the defaults.
    static let decodingLimits = OSCCodec.Limits(maxPacketBytes: SLIPCodec.maximumFrameSize)

    private var connection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?

    private var readiness: Result<Void, any Error>?
    private var readinessWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var readinessTimeout: Task<Void, Never>?

    private let queue = DispatchQueue(label: "org.arvadacenter.Cuety.connection")

    // Keep buffering bounded; the client resynchronizes when events are dropped.
    static let eventBufferCapacity = 512

    private(set) var droppedEventCount = 0

    private var onEventsDropped: (@Sendable (Int) async -> Void)?

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func setEventsDroppedHandler(_ handler: (@Sendable (Int) async -> Void)?) {
        onEventsDropped = handler
    }

    func start() -> AsyncStream<Event> {
        closeConnection()

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        self.continuation = continuation
        readiness = nil

        let connection = NWConnection(to: endpoint, using: .qlabTCP())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            Task { await self.handleStateChange(state, for: connection) }
        }

        connection.viabilityUpdateHandler = { [weak self, weak connection] isViable in
            guard let self, let connection else { return }
            Task { await self.handleViabilityChange(isViable, for: connection) }
        }

        connection.start(queue: queue)

        return stream
    }

    func cancel() {
        closeConnection()
        onEventsDropped = nil
    }

    /// Tears the socket down without forgetting who asked to hear about
    /// dropped events, so restarting keeps the owner's handler attached.
    private func closeConnection() {
        readinessTimeout?.cancel()
        readinessTimeout = nil
        dropReportTask?.cancel()
        dropReportTask = nil
        droppedEventCount = 0

        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = nil

        resolveReadiness(.failure(ConnectFailure.cancelled))

        continuation?.finish()
        continuation = nil
    }

    nonisolated enum ConnectFailure: LocalizedError {
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .timedOut: "QLab did not answer. It may have quit or moved."
            case .cancelled: "The connection was closed before it was ready."
            }
        }
    }

    func waitUntilReady(timeout: TimeInterval) async throws {
        if let readiness { return try readiness.get() }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if let readiness {
                    continuation.resume(with: readiness)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readinessWaiters.append((id: waiterID, continuation: continuation))
                if readinessTimeout == nil {
                    let currentConnection = connection
                    readinessTimeout = Task { [weak self, weak currentConnection] in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled else { return }
                        await self?.timeoutReadiness(for: currentConnection)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelReadinessWaiter(waiterID) }
        }
    }

    private func cancelReadinessWaiter(_ id: UUID) {
        guard let index = readinessWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = readinessWaiters.remove(at: index)
        if readinessWaiters.isEmpty, readiness == nil {
            readinessTimeout?.cancel()
            readinessTimeout = nil
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeoutReadiness(for timedOutConnection: NWConnection?) {
        guard connection === timedOutConnection else { return }
        resolveReadiness(.failure(ConnectFailure.timedOut))
    }

    private func resolveReadiness(_ result: Result<Void, any Error>) {
        guard readiness == nil else { return }
        readiness = result

        readinessTimeout?.cancel()
        readinessTimeout = nil

        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(with: result) }
    }

    @discardableResult
    func send(
        _ message: OSCMessage,
        trackedBy sendState: QLabSendState? = nil
    ) async throws -> Int {
        guard sendState?.begin() ?? true else {
            throw CancellationError()
        }
        guard let connection, connection.state == .ready else {
            throw SendFailure.notConnected
        }

        let packet = try OSCCodec.encode(message)

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: packet,
                completion: .contentProcessed { error in
                    if let error {
                        resume.resume(throwing: SendFailure.transport(error))
                    } else {
                        resume.resume()
                    }
                }
            )
        }

        return packet.count
    }

    nonisolated enum SendFailure: LocalizedError {
        case notConnected
        case transport(NWError)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to QLab."
            case .transport(let error): "Send failed: \(error.localizedDescription)"
            }
        }
    }

    private func receiveNextMessage(on connection: NWConnection) {
        guard let continuation else { return }
        Self.receiveNextMessage(on: connection, continuation: continuation, owner: self)
    }

    private nonisolated static func receiveNextMessage(
        on connection: NWConnection,
        continuation: AsyncStream<Event>.Continuation,
        owner: QLabConnection
    ) {
        connection.receiveMessage { [weak owner] content, _, isComplete, error in
            var droppedCount = 0
            var malformedError: String?

            if let content, !content.isEmpty {
                for event in Self.events(forPacket: content) {
                    if case .receiveFailed(let decodeError, _) = event {
                        malformedError = decodeError.description
                    }
                    switch continuation.yield(event) {
                    case .dropped:
                        droppedCount += 1
                    case .terminated:
                        return
                    default:
                        break
                    }
                }
            }

            if let error {
                if case .dropped = continuation.yield(.stateChanged(.failed(error))) {
                    droppedCount += 1
                }
                if droppedCount > 0 || malformedError != nil, let owner {
                    Task {
                        await owner.handleReceiveDiagnostics(
                            droppedCount: droppedCount,
                            malformedError: malformedError,
                            for: connection
                        )
                    }
                }
                return
            }

            if isComplete, content?.isEmpty ?? true {
                if case .dropped = continuation.yield(.stateChanged(.cancelled)) {
                    droppedCount += 1
                }
                if droppedCount > 0 || malformedError != nil, let owner {
                    Task {
                        await owner.handleReceiveDiagnostics(
                            droppedCount: droppedCount,
                            malformedError: malformedError,
                            for: connection
                        )
                    }
                }
                return
            }

            if droppedCount > 0 || malformedError != nil, let owner {
                Task {
                    await owner.handleReceiveDiagnostics(
                        droppedCount: droppedCount,
                        malformedError: malformedError,
                        for: connection
                    )
                }
            }

            guard let owner, connection.state == .ready else { return }
            Self.receiveNextMessage(on: connection, continuation: continuation, owner: owner)
        }
    }

    private func handleReceiveDiagnostics(
        droppedCount: Int,
        malformedError: String?,
        for connection: NWConnection
    ) {
        if let malformedError {
            logger.warning("Dropped malformed OSC packet: \(malformedError, privacy: .public)")
        }
        guard self.connection === connection else { return }
        if droppedCount > 0 {
            droppedEventCount += droppedCount
            notifyEventsDropped()
        }
    }

    /// One event per message a packet carries. A bundle's wire bytes are
    /// counted once, against its first message, so traffic totals match what
    /// crossed the network however many messages the bundle held.
    static func events(forPacket data: Data) -> [Event] {
        do {
            let packet = try OSCCodec.decode(data, limits: decodingLimits)
            return packet.flattenedMessages.enumerated().map { index, message in
                .received(message, byteCount: index == 0 ? data.count : 0)
            }
        } catch {
            return [.receiveFailed(error, byteCount: data.count)]
        }
    }

    private func handleStateChange(_ state: NWConnection.State, for connection: NWConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .ready:
            receiveNextMessage(on: connection)
            resolveReadiness(.success(()))
        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            resolveReadiness(.failure(error))
        case .cancelled:
            resolveReadiness(.failure(ConnectFailure.cancelled))
        default:
            break
        }
        yield(.stateChanged(state))
    }

    private func handleViabilityChange(_ isViable: Bool, for connection: NWConnection) {
        guard self.connection === connection else { return }
        yield(.pathChanged(isViable: isViable))
    }

    private func yield(_ event: Event) {
        guard let continuation else { return }

        switch continuation.yield(event) {
        case .enqueued:
            break

        case .dropped:
            droppedEventCount += 1
            notifyEventsDropped()

        case .terminated:
            break

        @unknown default:
            break
        }
    }

    private static let dropReportDelay: Duration = .milliseconds(100)

    private var dropReportTask: Task<Void, Never>?

    private func notifyEventsDropped() {
        guard onEventsDropped != nil, dropReportTask == nil else { return }

        dropReportTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dropReportDelay)
            await self?.reportDroppedEvents()
        }
    }

    private func reportDroppedEvents() async {
        dropReportTask = nil

        let lost = droppedEventCount
        droppedEventCount = 0
        guard lost > 0, let onEventsDropped else { return }

        await onEventsDropped(lost)
    }
}
