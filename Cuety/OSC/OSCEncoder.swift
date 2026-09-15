import Foundation

/// OSC wire values are 4-byte aligned; outgoing addresses are validated before encoding.

nonisolated struct OSCEncoder {
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
            data.appendBigEndian(Int32(encoded.count))
            data.append(encoded)
        }
        return data
    }
}


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

    mutating func appendOSCString(_ string: String) {
        let bytes = Array(string.utf8)
        append(contentsOf: bytes)
        let paddingCount = OSCEncoder.alignment - (bytes.count % OSCEncoder.alignment)
        append(contentsOf: repeatElement(0, count: paddingCount))
    }

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
            break
        }
    }
}
