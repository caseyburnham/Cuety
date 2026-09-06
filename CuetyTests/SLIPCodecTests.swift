import Foundation
import Testing

@testable import Cuety

/// SLIP framing conformance.
///
/// The behaviours asserted here are taken from Figure 53's own
/// `F53OSCParser.translateSlipData:toData:withState:destination:`, since F53OSC
/// defines what QLab actually puts on the wire. Where Cuety deliberately
/// diverges — the frame size cap — that is called out on the test.
@Suite("SLIP framing")
struct SLIPCodecTests {

    // MARK: - Constants

    /// RFC 1055 defines these as octal 300, 333, 334, 335.
    @Test("Uses the RFC 1055 constants")
    func constants() {
        #expect(SLIPCodec.end == 0o300)
        #expect(SLIPCodec.esc == 0o333)
        #expect(SLIPCodec.escEnd == 0o334)
        #expect(SLIPCodec.escEsc == 0o335)
    }

    // MARK: - Encoding

    @Test("Wraps payloads in the double-END form QLab documents")
    func encodesWithDoubleEnd() {
        let framed = SLIPCodec.encode(Data([0x41, 0x42]))
        #expect(framed == Data([SLIPCodec.end, 0x41, 0x42, SLIPCodec.end]))
    }

    @Test("Escapes literal END bytes in the payload")
    func escapesEnd() {
        let framed = SLIPCodec.encode(Data([SLIPCodec.end]))
        #expect(framed == Data([
            SLIPCodec.end, SLIPCodec.esc, SLIPCodec.escEnd, SLIPCodec.end,
        ]))
    }

    @Test("Escapes literal ESC bytes in the payload")
    func escapesEsc() {
        let framed = SLIPCodec.encode(Data([SLIPCodec.esc]))
        #expect(framed == Data([
            SLIPCodec.end, SLIPCodec.esc, SLIPCodec.escEsc, SLIPCodec.end,
        ]))
    }

    /// `ESC_END` and `ESC_ESC` are only special *after* an `ESC`; on their own
    /// they are ordinary payload bytes and must not be escaped.
    @Test("Leaves ESC_END and ESC_ESC alone when not preceded by ESC")
    func doesNotEscapeEscapeOperands() {
        let payload = Data([SLIPCodec.escEnd, SLIPCodec.escEsc])
        let framed = SLIPCodec.encode(payload)
        #expect(framed == Data([
            SLIPCodec.end, SLIPCodec.escEnd, SLIPCodec.escEsc, SLIPCodec.end,
        ]))
    }

    // MARK: - Round trips

    /// Payloads chosen to exercise every escaping path, including a run of
    /// every possible byte value.
    ///
    /// Held as an explicitly typed constant rather than inlined into the
    /// `@Test` attribute: as a literal it is slow enough to type-check that the
    /// compiler gives up.
    static let escapingPayloads: [Data] = {
        let allByteValues = Data(Array(UInt8.min...UInt8.max))
        return [
            Data([0x41]),
            Data([SLIPCodec.end]),
            Data([SLIPCodec.esc]),
            Data([SLIPCodec.end, SLIPCodec.esc]),
            Data([SLIPCodec.esc, SLIPCodec.escEnd]),
            Data([SLIPCodec.esc, SLIPCodec.escEsc]),
            Data([0xC0, 0xDB, 0xC0, 0xDB, 0xDC, 0x41, 0xC0]),
            Data(repeating: SLIPCodec.end, count: 64),
            Data(repeating: SLIPCodec.esc, count: 64),
            allByteValues,
        ]
    }()

    @Test(
        "Round-trips payloads containing the bytes that need escaping",
        arguments: SLIPCodecTests.escapingPayloads
    )
    func roundTrips(payload: Data) throws {
        let frames = try SLIPCodec.decodeAll(SLIPCodec.encode(payload))
        #expect(frames == [payload])
    }

    @Test("Round-trips a real OSC packet")
    func roundTripsOSCPacket() throws {
        let message = OSCMessage("/workspace/ABC/thump", [.string("thump")])
        let packet = OSCEncoder().encode(message)

        let frames = try SLIPCodec.decodeAll(SLIPCodec.encode(packet))
        let frame = try #require(frames.first)
        #expect(try OSCDecoder().decode(frame) == .message(message))
    }

    // MARK: - Empty frames
    //
    // F53OSC's `processOscData:` returns early on `length == 0`. Dropping
    // zero-length frames is the single mechanism that makes double-END and
    // single-END senders parse identically, with no version flag.

    @Test("Discards zero-length frames")
    func discardsEmptyFrames() throws {
        let frames = try SLIPCodec.decodeAll(Data([
            SLIPCodec.end, SLIPCodec.end, SLIPCodec.end,
        ]))
        #expect(frames.isEmpty)
    }

    @Test("Parses a single-END framed payload identically to a double-END one")
    func singleEndFramingIsEquivalent() throws {
        let payload = Data([0x2F, 0x61, 0x00, 0x00])

        // Double-END: delimiter on both sides.
        let double = try SLIPCodec.decodeAll(SLIPCodec.encode(payload))

        // Single-END: trailing delimiter only, as older QLab builds were
        // reported to send.
        var single = payload
        single.append(SLIPCodec.end)
        let singleFrames = try SLIPCodec.decodeAll(single)

        #expect(double == [payload])
        #expect(singleFrames == [payload])
        #expect(double == singleFrames)
    }

    @Test("Separates back-to-back frames, ignoring redundant delimiters")
    func separatesAdjacentFrames() throws {
        var stream = SLIPCodec.encode(Data([0x01]))
        stream.append(SLIPCodec.end)
        stream.append(contentsOf: SLIPCodec.encode(Data([0x02])))
        stream.append(contentsOf: SLIPCodec.encode(Data([0x03])))

        let frames = try SLIPCodec.decodeAll(stream)
        #expect(frames == [Data([0x01]), Data([0x02]), Data([0x03])])
    }

    // MARK: - Partial reads
    //
    // TCP gives no alignment guarantees, so the decoder must carry state
    // across reads — including F53OSC's `dangling_ESC` case.

    @Test("Withholds a frame until its delimiter arrives")
    func withholdsIncompleteFrame() throws {
        var decoder = SLIPCodec.Decoder()
        let framed = SLIPCodec.encode(Data([0x41, 0x42, 0x43]))

        let early = try decoder.decode(framed.dropLast())
        #expect(early.isEmpty)
        #expect(decoder.bufferedByteCount == 3)

        let completed = try decoder.decode([SLIPCodec.end])
        #expect(completed == [Data([0x41, 0x42, 0x43])])
        #expect(decoder.bufferedByteCount == 0)
    }

    /// The `dangling_ESC` case: a read boundary falling between `ESC` and the
    /// byte it escapes.
    @Test("Carries a dangling ESC across a read boundary")
    func carriesDanglingEscape() throws {
        var decoder = SLIPCodec.Decoder()

        // First read ends on the ESC byte itself.
        let first = try decoder.decode([SLIPCodec.esc])
        #expect(first.isEmpty)
        #expect(decoder.hasDanglingEscape)

        // Second read supplies the operand and the delimiter.
        let second = try decoder.decode([SLIPCodec.escEnd, SLIPCodec.end])
        #expect(second == [Data([SLIPCodec.end])])
        #expect(!decoder.hasDanglingEscape)
    }

    /// Feeding a stream one byte at a time is the harshest fragmentation
    /// possible, and must produce exactly the same frames as one bulk read.
    @Test("Decodes identically when fed one byte at a time")
    func decodesByteByByte() throws {
        let payloads = [
            Data([0xC0, 0xDB, 0x41]),
            Data([0x01, 0x02, 0x03]),
            Data([SLIPCodec.esc, SLIPCodec.escEnd]),
        ]
        var stream = Data()
        for payload in payloads {
            stream.append(contentsOf: SLIPCodec.encode(payload))
        }

        var decoder = SLIPCodec.Decoder()
        var frames: [Data] = []
        for byte in stream {
            frames.append(contentsOf: try decoder.decode([byte]))
        }
        #expect(frames == payloads)
    }

    @Test("Decodes identically at every possible split point")
    func decodesAtEverySplitPoint() throws {
        let payload = Data([0xC0, 0xDB, 0x41, 0xDC, 0xDD])
        let stream = SLIPCodec.encode(payload)

        for split in 0...stream.count {
            var decoder = SLIPCodec.Decoder()
            var frames: [Data] = []
            frames.append(contentsOf: try decoder.decode(stream.prefix(split)))
            frames.append(
                contentsOf: try decoder.decode(stream.suffix(stream.count - split))
            )
            #expect(frames == [payload], "split at \(split)")
        }
    }

    // MARK: - Leniency
    //
    // F53OSC appends the byte "as-is" when an ESC is followed by something
    // other than ESC_END or ESC_ESC. Cuety matches that: lenient about what it
    // accepts, strict about what it sends.

    @Test("Treats an invalid escape sequence as a literal byte")
    func lenientOnInvalidEscape() throws {
        // ESC followed by 'A', which is neither ESC_END nor ESC_ESC.
        let frames = try SLIPCodec.decodeAll(Data([
            SLIPCodec.end, SLIPCodec.esc, 0x41, 0x42, SLIPCodec.end,
        ]))
        #expect(frames == [Data([0x41, 0x42])])
    }

    @Test("Keeps the rest of a frame after an invalid escape sequence")
    func invalidEscapeDoesNotDropFrame() throws {
        var stream = Data([SLIPCodec.end, SLIPCodec.esc, 0x00, 0x41, SLIPCodec.end])
        stream.append(contentsOf: SLIPCodec.encode(Data([0x99])))

        let frames = try SLIPCodec.decodeAll(stream)
        #expect(frames.count == 2)
        #expect(frames.last == Data([0x99]))
    }

    // MARK: - Frame size cap
    //
    // A deliberate divergence: F53OSC has no limit. Cuety caps buffering so a
    // peer that never sends a delimiter cannot grow our memory without bound.

    @Test("Throws once an undelimited frame exceeds the cap")
    func enforcesFrameSizeCap() {
        var decoder = SLIPCodec.Decoder(maximumFrameSize: 64)

        #expect(throws: SLIPFramingError.self) {
            _ = try decoder.decode(Data(repeating: 0x41, count: 128))
        }
    }

    @Test("Accepts a frame exactly at the cap")
    func acceptsFrameAtCap() throws {
        var decoder = SLIPCodec.Decoder(maximumFrameSize: 64)
        let payload = Data(repeating: 0x41, count: 64)

        var frames = try decoder.decode(payload)
        #expect(frames.isEmpty)

        frames = try decoder.decode([SLIPCodec.end])
        #expect(frames == [payload])
    }

    @Test("Reports how much was buffered when the cap trips")
    func capErrorReportsDetails() throws {
        var decoder = SLIPCodec.Decoder(maximumFrameSize: 16)

        let error = try #require(throws: SLIPFramingError.self) {
            _ = try decoder.decode(Data(repeating: 0x41, count: 32))
        }
        #expect(error == .frameTooLarge(bytesBuffered: 17, limit: 16))
        #expect(!error.description.isEmpty)
    }

    /// After the cap trips the decoder is reset, so a caller that chooses to
    /// keep going is not stuck permanently over the limit.
    @Test("Resets after the cap trips")
    func resetsAfterCap() throws {
        var decoder = SLIPCodec.Decoder(maximumFrameSize: 16)
        _ = try? decoder.decode(Data(repeating: 0x41, count: 32))

        #expect(decoder.bufferedByteCount == 0)
        #expect(!decoder.hasDanglingEscape)

        let frames = try decoder.decode(SLIPCodec.encode(Data([0x01])))
        #expect(frames == [Data([0x01])])
    }

    // MARK: - Reset

    @Test("Reset discards partial state")
    func resetDiscardsPartialState() throws {
        var decoder = SLIPCodec.Decoder()
        _ = try decoder.decode([0x41, 0x42, SLIPCodec.esc])
        #expect(decoder.bufferedByteCount == 2)
        #expect(decoder.hasDanglingEscape)

        decoder.reset()
        #expect(decoder.bufferedByteCount == 0)
        #expect(!decoder.hasDanglingEscape)
    }
}
