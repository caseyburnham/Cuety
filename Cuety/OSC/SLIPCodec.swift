import Foundation

/// SLIP (RFC 1055) framing, as required for OSC 1.1 over TCP.
///
/// This type holds no Network framework state so it can be exercised directly
/// by unit tests; ``SLIPFramer`` is the thin adapter that plugs it into an
/// `NWConnection`.
///
/// The behaviour here is matched deliberately to Figure 53's own
/// `F53OSCParser.translateSlipData:toData:withState:destination:`, since F53OSC
/// defines what QLab actually puts on the wire:
///
/// - Zero-length frames are silently discarded. This is the single mechanism
///   that makes a double-END sender and a single-END sender parse identically,
///   with no version negotiation and no configuration flag.
/// - A dangling `ESC` at the end of a read is remembered, so an escape
///   sequence split across two TCP reads still decodes correctly.
/// - An `ESC` followed by anything other than `ESC_END` or `ESC_ESC` yields
///   that byte literally rather than failing the frame. Cuety is lenient about
///   what it accepts and strict about what it sends.
nonisolated enum SLIPCodec {
    /// Frame delimiter.
    static let end: UInt8 = 0xC0
    /// Escape prefix.
    static let esc: UInt8 = 0xDB
    /// Follows `esc` to mean a literal ``end`` byte.
    static let escEnd: UInt8 = 0xDC
    /// Follows `esc` to mean a literal ``esc`` byte.
    static let escEsc: UInt8 = 0xDD

    /// Wraps a payload in a SLIP frame using the double-END form that QLab documents.
    static func encode(_ payload: Data) -> Data {
        var framed = Data()
        // Worst case every byte needs escaping, plus the two delimiters.
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

    /// Incremental SLIP decoder.
    ///
    /// Feed it arbitrary byte runs — TCP gives no alignment guarantees — and it
    /// returns whole frames as they complete, carrying partial state between calls.
    struct Decoder {
        /// The largest unterminated frame to buffer before giving up.
        ///
        /// F53OSC imposes no limit. Cuety does, so that a wedged or hostile
        /// peer that never sends a delimiter cannot grow memory without bound.
        let maximumFrameSize: Int

        private var accumulator = Data()
        private var danglingESC = false

        init(maximumFrameSize: Int = 8 * 1024 * 1024) {
            self.maximumFrameSize = maximumFrameSize
        }

        /// Bytes buffered toward a frame that has not been delimited yet.
        var bufferedByteCount: Int { accumulator.count }

        /// Whether the previous run of bytes ended mid-escape-sequence.
        var hasDanglingEscape: Bool { danglingESC }

        mutating func reset() {
            accumulator.removeAll(keepingCapacity: false)
            danglingESC = false
        }

        /// Decodes a run of bytes, returning every frame completed by it.
        ///
        /// - Throws: ``SLIPFramingError/frameTooLarge`` if an undelimited frame
        ///   exceeds ``maximumFrameSize``. The decoder is left reset, since the
        ///   caller is expected to tear the connection down.
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
                        // Protocol violation by the peer. Pass the byte through
                        // rather than discarding the frame, matching F53OSC.
                        accumulator.append(byte)
                    }
                } else {
                    switch byte {
                    case SLIPCodec.end:
                        if !accumulator.isEmpty {
                            frames.append(accumulator)
                            accumulator.removeAll(keepingCapacity: true)
                        }
                        // An empty accumulator here means a zero-length frame:
                        // the leading delimiter of a double-END frame, or two
                        // adjacent delimiters. Dropping it is what makes both
                        // framing conventions work without a special case.
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

// MARK: - Convenience

nonisolated extension SLIPCodec {
    /// Decodes a complete, self-contained buffer in one call.
    ///
    /// Only appropriate when the whole stream is in hand — the connection path
    /// uses ``Decoder`` so that state survives across reads.
    static func decodeAll(_ data: Data, maximumFrameSize: Int = 8 * 1024 * 1024) throws -> [Data] {
        var decoder = Decoder(maximumFrameSize: maximumFrameSize)
        return try decoder.decode(data)
    }
}
