import Foundation
import Network
import os

/// Owns a single TCP connection to QLab and turns it into a stream of OSC messages.
///
/// An `actor` rather than a `@MainActor` class: `NWConnection` calls back on its
/// own queue, and decoding a large `/cueLists` reply has no business happening
/// on the main thread. Callers see an `AsyncStream` of ``Event`` and never touch
/// `NWConnection` directly.
///
/// Because ``SLIPFramer`` sits in the protocol stack, every `receiveMessage`
/// yields exactly one complete, unescaped OSC packet — there is no reassembly
/// logic here.
actor QLabConnection {

    /// Everything the connection can tell its owner about.
    enum Event: Sendable {
        case stateChanged(NWConnection.State)
        case pathChanged(isViable: Bool)
        /// A packet arrived and parsed.
        case received(OSCMessage, byteCount: Int)
        /// A packet arrived but could not be parsed. The connection stays up:
        /// one bad packet is not grounds for dropping the session.
        case receiveFailed(OSCDecodingError, byteCount: Int)
    }

    private let endpoint: NWEndpoint
    private let logger = Logger(subsystem: "com.caseyburnham.Cuety", category: "QLabConnection")
    private let encoder = OSCEncoder()
    private let decoder = OSCDecoder()

    private var connection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?

    /// How the current connection attempt resolved, once it has.
    ///
    /// Recorded rather than only signalled, so a caller that asks after the
    /// fact still gets an answer instead of waiting for a state change that
    /// has already been and gone.
    private var readiness: Result<Void, any Error>?
    private var readinessWaiters: [CheckedContinuation<Void, any Error>] = []
    private var readinessTimeout: Task<Void, Never>?

    /// Serial queue for all `NWConnection` callbacks.
    private let queue = DispatchQueue(label: "com.caseyburnham.Cuety.connection")

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    /// Convenience for a host and port.
    init(host: String, port: UInt16) {
        self.endpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 53000
        )
    }

    /// The endpoint this connection targets, for display in the inspector.
    var targetEndpoint: NWEndpoint { endpoint }

    // MARK: - Lifecycle

    /// Starts the connection and returns the event stream.
    ///
    /// Calling this twice cancels the previous connection first, so a caller
    /// cannot accidentally leak a socket by reconnecting.
    func start() -> AsyncStream<Event> {
        cancel()

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            // Buffer rather than drop: a burst of cue updates during a group
            // cue must not lose the playhead change hiding inside it.
            bufferingPolicy: .bufferingNewest(512)
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

        // The receive loop is armed from the `.ready` state change, not here:
        // posting a receive before the protocol stack is up would double-arm it.
        connection.start(queue: queue)

        return stream
    }

    func cancel() {
        readinessTimeout?.cancel()
        readinessTimeout = nil

        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = nil

        resolveReadiness(.failure(ConnectFailure.cancelled))

        continuation?.finish()
        continuation = nil
    }

    // MARK: - Readiness

    enum ConnectFailure: Error, CustomStringConvertible {
        /// The connection never came up before the deadline.
        ///
        /// This is the shape most QLab disappearances take. A Bonjour endpoint
        /// whose service record has gone leaves `NWConnection` resolving
        /// forever in `.waiting`, and an unreachable host does the same: the
        /// framework reports no failure because, as far as it is concerned,
        /// the attempt is still in progress.
        case timedOut
        /// The connection was torn down before it was ready.
        case cancelled

        var description: String {
            switch self {
            case .timedOut: "QLab did not answer. It may have quit or moved."
            case .cancelled: "The connection was closed before it was ready."
            }
        }
    }

    /// Waits for the connection to reach `.ready`, or gives up.
    ///
    /// Resolved from the state handler rather than by reading ``Event``s,
    /// because the event stream has exactly one consumer for the life of the
    /// session and `AsyncStream` terminates when the task iterating it is
    /// cancelled. A timeout built by racing the stream would therefore take
    /// the session's only event feed down with it.
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
        // First answer wins. A connection that failed and was then cancelled
        // should still report the failure, which is the useful half of the
        // story.
        guard readiness == nil else { return }
        readiness = result

        readinessTimeout?.cancel()
        readinessTimeout = nil

        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: - Sending

    /// Encodes and sends one OSC message.
    ///
    /// - Returns: The packet size in bytes, for the activity log.
    /// - Throws: ``SendFailure`` if the connection isn't up or the send fails.
    @discardableResult
    func send(_ message: OSCMessage) async throws -> Int {
        guard let connection, connection.state == .ready else {
            throw SendFailure.notConnected
        }

        let packet = encoder.encode(message)

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: packet,
                // The framer delimits messages, so every send is a complete
                // message rather than part of a stream.
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
            case .transport(let error): "Send failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Receiving

    /// Pulls one framed message and re-arms itself.
    ///
    /// Recursive rather than looping so each message is handed off before the
    /// next receive is posted, which keeps ordering intact.
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

                // `isComplete` with no content means the peer closed the stream.
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
            // A bundle is delivered as its constituent messages: Cuety
            // dispatches on addresses, and nothing it does cares about
            // bundle-level atomicity.
            for message in packet.flattenedMessages {
                yield(.received(message, byteCount: data.count))
            }
        } catch let error as OSCDecodingError {
            logger.warning("Dropped malformed OSC packet: \(error.description, privacy: .public)")
            yield(.receiveFailed(error, byteCount: data.count))
        } catch {
            logger.warning("Dropped unparseable OSC packet: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Plumbing

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // Only safe to arm the receive loop once the stack is up.
            if let connection { receiveNextMessage(on: connection) }
            resolveReadiness(.success(()))
        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            resolveReadiness(.failure(error))
        case .cancelled:
            resolveReadiness(.failure(ConnectFailure.cancelled))
        default:
            // `.waiting` is left alone deliberately: the system retries on its
            // own and often succeeds, so the only thing that should end the
            // wait early is a real failure. Everything else is the deadline's
            // job.
            break
        }
        yield(.stateChanged(state))
    }

    private func yield(_ event: Event) {
        continuation?.yield(event)
    }
}
