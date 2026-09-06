import Foundation

/// A failure encountered while decoding an OSC packet.
///
/// Every case carries the byte offset at which the problem was found, because
/// the Activity Log shows these to the user and "malformed packet" without a
/// location is not actionable.
nonisolated enum OSCDecodingError: Error, Hashable, Sendable {
    /// The packet ended while more bytes were still required.
    case unexpectedEnd(offset: Int, needed: Int, available: Int)
    /// An address pattern or string was not valid UTF-8.
    case invalidUTF8(offset: Int)
    /// A string was not terminated by a null byte before the packet ended.
    case unterminatedString(offset: Int)
    /// The packet's first byte was neither `/` (message) nor `#` (bundle).
    case notAPacket(offset: Int, firstByte: UInt8)
    /// An address pattern did not begin with `/`.
    case invalidAddress(offset: Int, address: String)
    /// The type tag string did not begin with `,`.
    case malformedTypeTagString(offset: Int)
    /// A type tag character has no defined representation.
    case unknownTypeTag(offset: Int, tag: Character)
    /// A bundle did not begin with the literal `#bundle`.
    case invalidBundleIdentifier(offset: Int)
    /// A bundle element declared a size that overruns the enclosing bundle.
    case bundleElementOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    /// A blob declared a size that overruns the packet.
    case blobOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    /// A declared size was negative, which the wire format cannot express.
    case negativeSize(offset: Int, declared: Int32)

    /// The byte offset the failure was detected at.
    var offset: Int {
        switch self {
        case .unexpectedEnd(let offset, _, _),
             .invalidUTF8(let offset),
             .unterminatedString(let offset),
             .notAPacket(let offset, _),
             .invalidAddress(let offset, _),
             .malformedTypeTagString(let offset),
             .unknownTypeTag(let offset, _),
             .invalidBundleIdentifier(let offset),
             .bundleElementOverrunsBuffer(let offset, _, _),
             .blobOverrunsBuffer(let offset, _, _),
             .negativeSize(let offset, _):
            offset
        }
    }
}

nonisolated extension OSCDecodingError: CustomStringConvertible {
    var description: String {
        switch self {
        case .unexpectedEnd(let offset, let needed, let available):
            "Packet ended at byte \(offset): needed \(needed) bytes, had \(available)."
        case .invalidUTF8(let offset):
            "Invalid UTF-8 in string at byte \(offset)."
        case .unterminatedString(let offset):
            "Unterminated string starting at byte \(offset)."
        case .notAPacket(let offset, let firstByte):
            "Not an OSC packet at byte \(offset): first byte is 0x\(String(firstByte, radix: 16)), expected '/' or '#'."
        case .invalidAddress(let offset, let address):
            "Address pattern at byte \(offset) does not begin with '/': \(address)"
        case .malformedTypeTagString(let offset):
            "Type tag string at byte \(offset) does not begin with ','."
        case .unknownTypeTag(let offset, let tag):
            "Unknown OSC type tag '\(tag)' at byte \(offset)."
        case .invalidBundleIdentifier(let offset):
            "Bundle at byte \(offset) does not begin with '#bundle'."
        case .bundleElementOverrunsBuffer(let offset, let declared, let remaining):
            "Bundle element at byte \(offset) declares \(declared) bytes but only \(remaining) remain."
        case .blobOverrunsBuffer(let offset, let declared, let remaining):
            "Blob at byte \(offset) declares \(declared) bytes but only \(remaining) remain."
        case .negativeSize(let offset, let declared):
            "Negative size \(declared) declared at byte \(offset)."
        }
    }
}

/// A failure in the SLIP framing layer.
nonisolated enum SLIPFramingError: Error, Hashable, Sendable {
    /// An unterminated frame exceeded ``SLIPFramer/maximumFrameSize``.
    ///
    /// Cuety fails the connection rather than continuing to buffer. F53OSC has
    /// no such limit; this is a deliberate divergence so that a wedged or
    /// hostile peer cannot grow our memory without bound.
    case frameTooLarge(bytesBuffered: Int, limit: Int)
}

nonisolated extension SLIPFramingError: CustomStringConvertible {
    var description: String {
        switch self {
        case .frameTooLarge(let buffered, let limit):
            "SLIP frame exceeded the \(limit)-byte limit (\(buffered) bytes buffered without a frame delimiter)."
        }
    }
}
