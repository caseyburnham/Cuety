import Foundation
import Testing

@testable import Cuety

@Suite("OSC codec")
struct OSCCodecTests {
    let encoder = OSCEncoder()
    let decoder = OSCDecoder()

    // MARK: - Round trips

    /// Every argument type must survive an encode/decode cycle unchanged.
    @Test(
        "Round-trips every argument type",
        arguments: [
            OSCValue.int32(0),
            .int32(-1),
            .int32(.max),
            .int32(.min),
            .float32(0),
            .float32(-0.5),
            .float32(.pi),
            .string(""),
            .string("hello"),
            .string("four"),
            .string("émoji 🎭 multibyte"),
            .symbol("sym"),
            .blob(Data()),
            .blob(Data([1])),
            .blob(Data([1, 2, 3, 4])),
            .blob(Data([0xC0, 0xDB, 0x00])),
            .int64(0),
            .int64(.max),
            .int64(.min),
            .double(0),
            .double(.pi),
            .timeTag(.immediate),
            .timeTag(OSCTimeTag(rawValue: 0xDEAD_BEEF_CAFE_F00D)),
            .true,
            .false,
            .null,
            .impulse,
        ]
    )
    func roundTripsArgument(_ argument: OSCValue) throws {
        let message = OSCMessage("/test", [argument])
        let decoded = try decoder.decode(encoder.encode(message))
        #expect(decoded == .message(message))
    }

    @Test("Round-trips a message with many mixed arguments")
    func roundTripsMixedArguments() throws {
        let message = OSCMessage("/workspace/ABC/cue_id/xyz/valuesForKeys", [
            .string(#"["number","name"]"#),
            .int32(42),
            .float32(0.5),
            .true,
            .null,
            .impulse,
            .false,
            .int64(9_000_000_000),
            .double(3.141592653589793),
            .blob(Data([0xC0, 0xDB, 0x00, 0x01, 0x02])),
        ])
        let decoded = try decoder.decode(encoder.encode(message))
        #expect(decoded == .message(message))
    }

    @Test("Round-trips a message with no arguments")
    func roundTripsZeroArguments() throws {
        let message = OSCMessage("/workspace/ABC/thump")
        let decoded = try decoder.decode(encoder.encode(message))
        #expect(decoded == .message(message))
    }

    // MARK: - Alignment

    /// Everything OSC puts on the wire is a multiple of four bytes.
    @Test("Encoded packets are always 4-byte aligned", arguments: 0...16)
    func encodedPacketsAreAligned(addressLength: Int) throws {
        let address = "/" + String(repeating: "a", count: addressLength)
        let message = OSCMessage(address, [
            .string(String(repeating: "b", count: addressLength)),
            .blob(Data(repeating: 0xFF, count: addressLength)),
        ])
        let encoded = encoder.encode(message)
        #expect(encoded.count % OSCEncoder.alignment == 0)
        #expect(try decoder.decode(encoded) == .message(message))
    }

    /// A string whose length is already a multiple of four still gets a full
    /// four bytes of padding, because the null terminator is mandatory.
    @Test("Aligned-length strings gain full padding")
    func alignedStringsGainFullPadding() {
        var data = Data()
        data.appendOSCString("four")
        #expect(data.count == 8)
        #expect(data.suffix(4) == Data([0, 0, 0, 0]))
    }

    @Test("Empty strings encode as four null bytes")
    func emptyStringEncoding() {
        var data = Data()
        data.appendOSCString("")
        #expect(data == Data([0, 0, 0, 0]))
    }

    /// Blob padding pads the contents, not the length prefix.
    @Test(
        "Blob encoding pads contents to a 4-byte boundary",
        arguments: [(0, 4), (1, 8), (2, 8), (3, 8), (4, 8), (5, 12)]
    )
    func blobPadding(contentLength: Int, expectedTotal: Int) {
        var data = Data()
        data.appendOSCBlob(Data(repeating: 0xAB, count: contentLength))
        #expect(data.count == expectedTotal)
    }

    // MARK: - Bundles

    @Test("Round-trips a bundle of messages")
    func roundTripsBundle() throws {
        let bundle = OSCBundle(timeTag: .immediate, elements: [
            .message(OSCMessage("/one", [.int32(1)])),
            .message(OSCMessage("/two", [.string("two")])),
        ])
        let decoded = try decoder.decode(encoder.encode(bundle))
        #expect(decoded == .bundle(bundle))
    }

    @Test("Round-trips nested bundles and flattens their messages")
    func roundTripsNestedBundle() throws {
        let inner = OSCBundle(elements: [.message(OSCMessage("/inner"))])
        let outer = OSCBundle(elements: [
            .message(OSCMessage("/outer")),
            .bundle(inner),
        ])
        let decoded = try decoder.decode(encoder.encode(outer))
        #expect(decoded == .bundle(outer))
        #expect(decoded.flattenedMessages.map(\.address) == ["/outer", "/inner"])
    }

    @Test("Rejects a bundle whose identifier is wrong")
    func rejectsBadBundleIdentifier() {
        var data = Data()
        data.appendOSCString("#wrong")
        data.appendBigEndian(UInt64(1))

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    /// F53OSC checks that a declared element length fits the enclosing bundle.
    /// Without this, a corrupt length reads past the end of the packet.
    @Test("Rejects a bundle element that overruns the buffer")
    func rejectsOverrunningBundleElement() {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(Int32(9999))
        data.append(contentsOf: [0x2F, 0x61, 0x00, 0x00])

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects a negative bundle element size")
    func rejectsNegativeBundleElementSize() {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(Int32(-8))

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    // MARK: - Malformed input
    //
    // These all mirror `F53OSCParser`'s validation. The contract is that a bad
    // packet throws a typed error the caller can log — never a crash, and never
    // a silently wrong result.

    @Test("Rejects a packet that is neither a message nor a bundle")
    func rejectsNonPacket() {
        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(Data([0x41, 0x42, 0x43, 0x00]))
        }
    }

    @Test("Rejects empty input")
    func rejectsEmptyInput() {
        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(Data())
        }
    }

    @Test("Rejects an unterminated address string")
    func rejectsUnterminatedString() {
        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(Data([0x2F, 0x61, 0x62, 0x63]))
        }
    }

    @Test("Rejects a type tag string that does not begin with a comma")
    func rejectsMalformedTypeTagString() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString("xi")
        data.appendBigEndian(Int32(1))

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    /// An unknown tag has an unknown width, so parsing cannot continue past it.
    @Test("Rejects an unknown type tag")
    func rejectsUnknownTypeTag() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",Q")
        data.appendBigEndian(Int32(1))

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects an argument whose payload is truncated")
    func rejectsTruncatedArgument() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",i")
        data.append(contentsOf: [0x00, 0x00])

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects a blob that overruns the buffer")
    func rejectsOverrunningBlob() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",b")
        data.appendBigEndian(Int32(9999))
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04])

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects a negative blob size")
    func rejectsNegativeBlobSize() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",b")
        data.appendBigEndian(Int32(-4))

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects an address that does not begin with a slash")
    func rejectsAddressWithoutLeadingSlash() {
        // Craft it by hand: the encoder would trip its own precondition.
        var data = Data()
        data.appendOSCString("#notbundle/x")

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    @Test("Rejects invalid UTF-8 in a string")
    func rejectsInvalidUTF8() {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",s")
        // 0xFF is never valid in UTF-8.
        data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])

        #expect(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
    }

    /// Decoding errors carry a byte offset, because "malformed packet" with no
    /// location is not actionable in the Activity Log.
    @Test("Decoding errors report a byte offset")
    func errorsCarryOffset() throws {
        var data = Data()
        data.appendOSCString("/test")
        data.appendOSCString(",i")

        let error = try #require(throws: OSCDecodingError.self) {
            _ = try decoder.decode(data)
        }
        #expect(error.offset > 0)
        #expect(!error.description.isEmpty)
    }

    // MARK: - Address handling

    @Test(
        "Validates outgoing addresses",
        arguments: [
            ("/cue/1/start", true),
            ("/cue/*/stop", true),
            ("/workspace/ABC/cueLists", true),
            ("/cue/{1,2}/start", true),
            ("no/leading/slash", false),
            ("", false),
            ("/has space", false),
            ("/has\ttab", false),
        ]
    )
    func validatesOutgoingAddresses(address: String, expected: Bool) {
        #expect(OSCMessage(address).isValidForSending == expected)
    }

    @Test("Splits addresses into components")
    func splitsAddressComponents() {
        let message = OSCMessage("/update/workspace/ABC/cueList/DEF/playbackPosition")
        #expect(message.addressComponents == [
            "update", "workspace", "ABC", "cueList", "DEF", "playbackPosition",
        ])
    }

    // MARK: - Value accessors

    @Test("Reads booleans from both tag-only and numeric forms")
    func readsBooleans() {
        #expect(OSCValue.true.boolValue == true)
        #expect(OSCValue.false.boolValue == false)
        #expect(OSCValue.int32(1).boolValue == true)
        #expect(OSCValue.int32(0).boolValue == false)
        #expect(OSCValue.string("nope").boolValue == nil)
    }

    @Test("Reads strings from both string and symbol cases")
    func readsStrings() {
        #expect(OSCValue.string("a").stringValue == "a")
        #expect(OSCValue.symbol("b").stringValue == "b")
        #expect(OSCValue.int32(1).stringValue == nil)
    }

    // MARK: - Time tags

    @Test("Time tag survives a date round trip within a millisecond")
    func timeTagRoundTrip() throws {
        let now = Date()
        let recovered = try #require(OSCTimeTag(date: now).date)
        #expect(abs(recovered.timeIntervalSince(now)) < 0.001)
    }

    @Test("The immediate time tag has no date")
    func immediateTimeTagHasNoDate() {
        #expect(OSCTimeTag.immediate.isImmediate)
        #expect(OSCTimeTag.immediate.date == nil)
    }

    /// A bad system clock must not be able to trap the app.
    @Test("Pre-1900 dates clamp instead of trapping")
    func prehistoricDatesClamp() {
        let ancient = Date(timeIntervalSince1970: -3_000_000_000)
        #expect(OSCTimeTag(date: ancient).rawValue == 0)
    }
}
