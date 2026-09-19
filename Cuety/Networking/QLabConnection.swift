import Foundation
import Network
import os

/// `NWConnection` callbacks arrive on its queue; the actor isolates connection state.

actor QLabConnection {

    enum Event: Sendable {
        case stateChanged(NWConnection.State)
        case pathChanged(isViable: Bool)
        case received(OSCMessage, byteCount: Int)
        case receiveFailed(OSCDecodingError, byteCount: Int)
    }

    private let endpoint: NWEndpoint
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "QLabConnection")
    private let encoder = OSCEncoder()
    private let decoder = OSCDecoder()

    private var connection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?

    private var readiness: Result<Void, any Error>?
    private var readinessWaiters: [CheckedContinuation<Void, any Error>] = []
    private var readinessTimeout: Task<Void, Never>?

    private let queue = DispatchQueue(label: "com.ivxx.Cuety.connection")

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
        cancel()

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        self.continuation = continuation
        readiness = nil

        let connection = NWConnection(to: endpoint, using: .qlabTCP())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateChange(state) }
        }

        connection.viabilityUpdateHandler = { [weak self] isViable in
            guard let self else { return }
            Task { await self.yield(.pathChanged(isViable: isViable)) }
        }

        connection.start(queue: queue)

        return stream
    }

    func cancel() {
        readinessTimeout?.cancel()
        readinessTimeout = nil
        dropReportTask?.cancel()
        dropReportTask = nil
        onEventsDropped = nil

        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = nil

        resolveReadiness(.failure(ConnectFailure.cancelled))

        continuation?.finish()
        continuation = nil
    }


    enum ConnectFailure: Error, CustomStringConvertible {
        case timedOut
        case cancelled

        var description: String {
            switch self {
            case .timedOut: "QLab did not answer. It may have quit or moved."
            case .cancelled: "The connection was closed before it was ready."
            }
        }
    }

    func waitUntilReady(timeout: TimeInterval) async throws {
        if let readiness { return try readiness.get() }

        if readinessTimeout == nil {
            readinessTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.resolveReadiness(.failure(ConnectFailure.timedOut))
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    private func resolveReadiness(_ result: Result<Void, any Error>) {
        guard readiness == nil else { return }
        readiness = result

        readinessTimeout?.cancel()
        readinessTimeout = nil

        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }


    @discardableResult
    func send(_ message: OSCMessage) async throws -> Int {
        guard let connection, connection.state == .ready else {
            throw SendFailure.notConnected
        }

        let packet = encoder.encode(message)

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

    enum SendFailure: Error, CustomStringConvertible {
        case notConnected
        case transport(NWError)

        var description: String {
            switch self {
            case .notConnected: "Not connected to QLab."
            case .transport(let error): "Send failed: \(error.operatorDescription)"
            }
        }
    }


    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }

            Task {
                if let content, !content.isEmpty {
                    await self.handleReceived(content)
                }

                if let error {
                    await self.yield(.stateChanged(.failed(error)))
                    return
                }

                if isComplete, content?.isEmpty ?? true {
                    await self.yield(.stateChanged(.cancelled))
                    return
                }

                await self.rearmReceive()
            }
        }
    }

    private func rearmReceive() {
        guard let connection, connection.state == .ready else { return }
        receiveNextMessage(on: connection)
    }

    private func handleReceived(_ data: Data) {
        do {
            let packet = try decoder.decode(data)
            for message in packet.flattenedMessages {
                yield(.received(message, byteCount: data.count))
            }
        } catch let error as OSCDecodingError {
            logger.warning("Dropped malformed OSC packet: \(error.description, privacy: .public)")
            yield(.receiveFailed(error, byteCount: data.count))
        } catch {
            logger.warning("Dropped unparseable OSC packet: \(error.operatorDescription, privacy: .public)")
        }
    }


    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if let connection { receiveNextMessage(on: connection) }
            resolveReadiness(.success(()))
        case .failed(let error):
            logger.error("Connection failed: \(error.operatorDescription, privacy: .public)")
            resolveReadiness(.failure(error))
        case .cancelled:
            resolveReadiness(.failure(ConnectFailure.cancelled))
        default:
            break
        }
        yield(.stateChanged(state))
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
