import Foundation

/// SLIP (RFC 1055) framing for OSC 1.1 over TCP; decoding retains partial-read state.
nonisolated enum SLIPCodec {
    /// QLab replies can carry a whole workspace of JSON in one frame.
    static let maximumFrameSize = 8 * 1024 * 1024

    static let end: UInt8 = 0xC0
    static let esc: UInt8 = 0xDB
    static let escEnd: UInt8 = 0xDC
    static let escEsc: UInt8 = 0xDD

    static func encode(_ payload: Data) -> Data {
        var framed = Data()
        framed.reserveCapacity(payload.count + 2)
        framed.append(end)
        for byte in payload {
            switch byte {
            case end:
                framed.append(esc)
                framed.append(escEnd)
            case esc:
                framed.append(esc)
                framed.append(escEsc)
            default:
                framed.append(byte)
            }
        }
        framed.append(end)
        return framed
    }

    struct Decoder {
        let maximumFrameSize: Int

        /// The frame read so far, still waiting for its closing delimiter.
        private(set) var buffer = Data()
        private(set) var hasDanglingEscape = false

        init(maximumFrameSize: Int = SLIPCodec.maximumFrameSize) {
            self.maximumFrameSize = maximumFrameSize
        }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: false)
            hasDanglingEscape = false
        }

        mutating func decode(_ bytes: some Collection<UInt8>) throws(SLIPFramingError) -> [Data] {
            var frames: [Data] = []

            for byte in bytes {
                if hasDanglingEscape {
                    hasDanglingEscape = false
                    switch byte {
                    case SLIPCodec.escEnd:
                        buffer.append(SLIPCodec.end)
                    case SLIPCodec.escEsc:
                        buffer.append(SLIPCodec.esc)
                    default:
                        buffer.append(byte)
                    }
                } else {
                    switch byte {
                    case SLIPCodec.end:
                        if !buffer.isEmpty {
                            frames.append(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                        continue
                    case SLIPCodec.esc:
                        hasDanglingEscape = true
                        continue
                    default:
                        buffer.append(byte)
                    }
                }

                if buffer.count > maximumFrameSize {
                    let buffered = buffer.count
                    reset()
                    throw .frameTooLarge(
                        bytesBuffered: buffered, limit: maximumFrameSize
                    )
                }
            }

            return frames
        }
    }
}

nonisolated enum SLIPFramingError: LocalizedError, Hashable, Sendable {
    case frameTooLarge(bytesBuffered: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let buffered, let limit):
            "SLIP frame exceeded the \(limit)-byte limit (\(buffered) bytes buffered without a frame delimiter)."
        }
    }
}
