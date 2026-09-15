import Foundation

nonisolated enum OSCDecodingError: Error, Hashable, Sendable {
    case unexpectedEnd(offset: Int, needed: Int, available: Int)
    case invalidUTF8(offset: Int)
    case unterminatedString(offset: Int)
    case notAPacket(offset: Int, firstByte: UInt8)
    case invalidAddress(offset: Int, address: String)
    case malformedTypeTagString(offset: Int)
    case unknownTypeTag(offset: Int, tag: Character)
    case invalidBundleIdentifier(offset: Int)
    case bundleElementOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    case blobOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    case negativeSize(offset: Int, declared: Int32)

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

nonisolated enum SLIPFramingError: Error, Hashable, Sendable {
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
