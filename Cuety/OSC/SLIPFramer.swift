import Foundation
import Network

/// Custom `NWProtocolFramer` for SLIP-framed OSC; Network drives it on the connection queue.

nonisolated final class SLIPFramer: NWProtocolFramerImplementation {
    static let label = "SLIP"

    static let definition = NWProtocolFramer.Definition(implementation: SLIPFramer.self)

    static let maximumFrameSize = 8 * 1024 * 1024

    private static let readChunkSize = 64 * 1024

    private var decoder = SLIPCodec.Decoder(maximumFrameSize: SLIPFramer.maximumFrameSize)

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    func cleanup(framer: NWProtocolFramer.Instance) {
        decoder.reset()
    }


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
                }
                consumed = buffer.count
                return consumed
            }

            if oversizeFailure != nil {
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

            if !didParse || consumed == 0 {
                return 0
            }
        }
    }


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

        guard didParse, payload.count == messageLength else { return }

        framer.writeOutput(data: SLIPCodec.encode(payload))
    }
}


nonisolated extension NWParameters {
    static func qlabTCP() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
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
