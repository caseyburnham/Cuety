import Foundation

/// SLIP (RFC 1055) framing for OSC 1.1 over TCP; decoding retains partial-read state.

nonisolated enum SLIPCodec {
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

        private var accumulator = Data()
        private var danglingESC = false

        init(maximumFrameSize: Int = 8 * 1024 * 1024) {
            self.maximumFrameSize = maximumFrameSize
        }

        var bufferedByteCount: Int { accumulator.count }

        var hasDanglingEscape: Bool { danglingESC }

        mutating func reset() {
            accumulator.removeAll(keepingCapacity: false)
            danglingESC = false
        }

        mutating func decode(_ bytes: some Collection<UInt8>) throws -> [Data] {
            var frames: [Data] = []

            for byte in bytes {
                if danglingESC {
                    danglingESC = false
                    switch byte {
                    case SLIPCodec.escEnd:
                        accumulator.append(SLIPCodec.end)
                    case SLIPCodec.escEsc:
                        accumulator.append(SLIPCodec.esc)
                    default:
                        accumulator.append(byte)
                    }
                } else {
                    switch byte {
                    case SLIPCodec.end:
                        if !accumulator.isEmpty {
                            frames.append(accumulator)
                            accumulator.removeAll(keepingCapacity: true)
                        }
                        continue
                    case SLIPCodec.esc:
                        danglingESC = true
                        continue
                    default:
                        accumulator.append(byte)
                    }
                }

                if accumulator.count > maximumFrameSize {
                    let buffered = accumulator.count
                    reset()
                    throw SLIPFramingError.frameTooLarge(
                        bytesBuffered: buffered, limit: maximumFrameSize
                    )
                }
            }

            return frames
        }
    }
}


nonisolated extension SLIPCodec {
    static func decodeAll(_ data: Data, maximumFrameSize: Int = 8 * 1024 * 1024) throws -> [Data] {
        var decoder = Decoder(maximumFrameSize: maximumFrameSize)
        return try decoder.decode(data)
    }
}
