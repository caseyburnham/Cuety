import Foundation

/// Serialises OSC packets to their wire representation.
///
/// Encoding is deliberately strict: an address that cannot be sent is a
/// programming error in Cuety, not a runtime condition to recover from, so it
/// trips a precondition rather than returning an optional that every call site
/// would have to unwrap. Decoding, by contrast, is lenient — see ``OSCDecoder``.
nonisolated struct OSCEncoder {
    /// All OSC data is aligned to 4-byte boundaries.
    static let alignment = 4

    func encode(_ packet: OSCPacket) -> Data {
        switch packet {
        case .message(let message): encode(message)
        case .bundle(let bundle): encode(bundle)
        }
    }

    func encode(_ message: OSCMessage) -> Data {
        precondition(
            message.isValidForSending,
            "Attempted to send a malformed OSC address: \(message.address)"
        )

        var data = Data()
        data.appendOSCString(message.address)

        // The type tag string is a comma followed by one tag per argument.
        var typeTags = ","
        for argument in message.arguments {
            typeTags.append(argument.typeTag)
        }
        data.appendOSCString(typeTags)

        for argument in message.arguments {
            data.appendOSCArgument(argument)
        }
        return data
    }

    func encode(_ bundle: OSCBundle) -> Data {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(bundle.timeTag.rawValue)

        for element in bundle.elements {
            let encoded = encode(element)
            // Each element is length-prefixed. Elements are always a multiple
            // of 4 bytes long, so no additional padding is needed here.
            data.appendBigEndian(Int32(encoded.count))
            data.append(encoded)
        }
        return data
    }
}

// MARK: - Wire primitives

nonisolated extension Data {
    mutating func appendBigEndian(_ value: Int32) {
        appendBigEndian(UInt32(bitPattern: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    mutating func appendBigEndian(_ value: Int64) {
        appendBigEndian(UInt64(bitPattern: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        appendBigEndian(UInt32(truncatingIfNeeded: value >> 32))
        appendBigEndian(UInt32(truncatingIfNeeded: value))
    }

    /// Appends an OSC string: UTF-8 bytes, at least one null terminator, then
    /// null padding to the next 4-byte boundary.
    ///
    /// A string whose UTF-8 length is already a multiple of 4 still gains a
    /// full 4 bytes of padding, because the terminator is mandatory.
    mutating func appendOSCString(_ string: String) {
        let bytes = Array(string.utf8)
        append(contentsOf: bytes)
        let paddingCount = OSCEncoder.alignment - (bytes.count % OSCEncoder.alignment)
        append(contentsOf: repeatElement(0, count: paddingCount))
    }

    /// Appends an OSC blob: a big-endian length, the bytes, then null padding
    /// to the next 4-byte boundary. The padding is not counted in the length.
    mutating func appendOSCBlob(_ blob: Data) {
        appendBigEndian(Int32(blob.count))
        append(blob)
        let remainder = blob.count % OSCEncoder.alignment
        if remainder != 0 {
            append(contentsOf: repeatElement(0, count: OSCEncoder.alignment - remainder))
        }
    }

    mutating func appendOSCArgument(_ argument: OSCValue) {
        switch argument {
        case .int32(let value):
            appendBigEndian(value)
        case .float32(let value):
            appendBigEndian(value.bitPattern)
        case .string(let value), .symbol(let value):
            appendOSCString(value)
        case .blob(let value):
            appendOSCBlob(value)
        case .int64(let value):
            appendBigEndian(value)
        case .double(let value):
            appendBigEndian(value.bitPattern)
        case .timeTag(let value):
            appendBigEndian(value.rawValue)
        case .true, .false, .null, .impulse:
            // Zero-width: the type tag alone carries the value.
            break
        }
    }
}
