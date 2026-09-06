import Foundation
import Network

/// Plugs ``SLIPCodec`` into an `NWConnection` as a custom application protocol.
///
/// With this in the protocol stack, `NWConnection` receives and sends whole OSC
/// packets: every `receiveMessage` delivers exactly one unescaped packet, and
/// every `send` is framed automatically. No buffer stitching at the call site.
///
/// Framer instances are created and driven by the Network framework on the
/// connection's own queue, one instance per connection, and never concurrently.
/// The mutable decoder state below is therefore confined to that queue.
nonisolated final class SLIPFramer: NWProtocolFramerImplementation {
    static let label = "SLIP"

    /// The definition to insert into `NWParameters.defaultProtocolStack.applicationProtocols`.
    static let definition = NWProtocolFramer.Definition(implementation: SLIPFramer.self)

    /// Matches ``SLIPCodec/Decoder/maximumFrameSize``'s default.
    static let maximumFrameSize = 8 * 1024 * 1024

    /// How much inbound data to take from the framework per parse call.
    private static let readChunkSize = 64 * 1024

    private var decoder = SLIPCodec.Decoder(maximumFrameSize: SLIPFramer.maximumFrameSize)

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // SLIP has no handshake, so the connection can become ready immediately.
        .ready
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    func cleanup(framer: NWProtocolFramer.Instance) {
        decoder.reset()
    }

    // MARK: - Inbound

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var completedFrames: [Data] = []
            var oversizeFailure: SLIPFramingError?
            var consumed = 0

            let didParse = framer.parseInput(
                minimumIncompleteLength: 1,
                maximumLength: Self.readChunkSize
            ) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                do {
                    completedFrames = try decoder.decode(buffer.bindMemory(to: UInt8.self))
                } catch let error as SLIPFramingError {
                    oversizeFailure = error
                } catch {
                    // `SLIPCodec.Decoder` throws nothing else, but swallowing
                    // here keeps the framer callback non-throwing regardless.
                }
                // The whole buffer is always consumed: the decoder retains any
                // partial frame internally, so these bytes never need revisiting.
                consumed = buffer.count
                return consumed
            }

            if oversizeFailure != nil {
                // A peer that never delimits a frame is not something we can
                // resynchronise with, so fail the connection rather than
                // silently truncating and delivering a corrupt packet.
                framer.markFailed(error: NWError.posix(.EMSGSIZE))
                return 0
            }

            for frame in completedFrames {
                framer.deliverInput(
                    data: frame,
                    message: NWProtocolFramer.Message(instance: framer),
                    isComplete: true
                )
            }

            // `didParse == false` means no bytes were available; `consumed == 0`
            // means we made no progress. Either way, wait for more data rather
            // than spinning.
            if !didParse || consumed == 0 {
                return 0
            }
        }
    }

    // MARK: - Outbound

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        guard messageLength > 0 else { return }

        var payload = Data()
        payload.reserveCapacity(messageLength)

        let didParse = framer.parseOutput(
            minimumIncompleteLength: messageLength,
            maximumLength: messageLength
        ) { buffer, _ in
            guard let buffer, buffer.count >= messageLength else { return 0 }
            payload.append(
                contentsOf: UnsafeRawBufferPointer(rebasing: buffer[0..<messageLength])
            )
            return messageLength
        }

        // If the full message isn't available in one span there is nothing
        // useful to emit — writing a partial frame would corrupt the stream.
        guard didParse, payload.count == messageLength else { return }

        framer.writeOutput(data: SLIPCodec.encode(payload))
    }
}

// MARK: - Parameters

nonisolated extension NWParameters {
    /// TCP parameters carrying the SLIP framer, for talking to QLab.
    ///
    /// `noDelay` matters here: cue changes are small, latency-sensitive
    /// messages, and Nagle's algorithm would batch them behind each other.
    static func qlabTCP() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        // Detect a dead peer reasonably quickly without being trigger-happy;
        // a show network can hiccup without the connection being gone.
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveCount = 3
        tcpOptions.keepaliveInterval = 5

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .responsiveData

        let slipOptions = NWProtocolFramer.Options(definition: SLIPFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(slipOptions, at: 0)

        return parameters
    }
}
