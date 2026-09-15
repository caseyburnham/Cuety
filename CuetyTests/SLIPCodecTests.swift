import Foundation
import Testing

@testable import Cuety

@Suite("SLIP framing")
struct SLIPCodecTests {


    @Test("Uses the RFC 1055 constants")
    func constants() {
        #expect(SLIPCodec.end == 0o300)
        #expect(SLIPCodec.esc == 0o333)
        #expect(SLIPCodec.escEnd == 0o334)
        #expect(SLIPCodec.escEsc == 0o335)
    }


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

    @Test("Leaves ESC_END and ESC_ESC alone when not preceded by ESC")
    func doesNotEscapeEscapeOperands() {
        let payload = Data([SLIPCodec.escEnd, SLIPCodec.escEsc])
        let framed = SLIPCodec.encode(payload)
        #expect(framed == Data([
            SLIPCodec.end, SLIPCodec.escEnd, SLIPCodec.escEsc, SLIPCodec.end,
        ]))
    }


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

        let double = try SLIPCodec.decodeAll(SLIPCodec.encode(payload))

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

    @Test("Carries a dangling ESC across a read boundary")
    func carriesDanglingEscape() throws {
        var decoder = SLIPCodec.Decoder()

        let first = try decoder.decode([SLIPCodec.esc])
        #expect(first.isEmpty)
        #expect(decoder.hasDanglingEscape)

        let second = try decoder.decode([SLIPCodec.escEnd, SLIPCodec.end])
        #expect(second == [Data([SLIPCodec.end])])
        #expect(!decoder.hasDanglingEscape)
    }

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


    @Test("Treats an invalid escape sequence as a literal byte")
    func lenientOnInvalidEscape() throws {
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

    @Test("Resets after the cap trips")
    func resetsAfterCap() throws {
        var decoder = SLIPCodec.Decoder(maximumFrameSize: 16)
        _ = try? decoder.decode(Data(repeating: 0x41, count: 32))

        #expect(decoder.bufferedByteCount == 0)
        #expect(!decoder.hasDanglingEscape)

        let frames = try decoder.decode(SLIPCodec.encode(Data([0x01])))
        #expect(frames == [Data([0x01])])
    }


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
