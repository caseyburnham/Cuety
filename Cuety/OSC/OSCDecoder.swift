import Foundation

/// Parses OSC 1.0/1.1 packets, including nested bundles, with bounds-checked reads.

nonisolated struct OSCDecoder {

    func decode(_ data: Data) throws -> OSCPacket {
        var reader = OSCReader(bytes: Array(data))
        return try decodePacket(&reader, limit: reader.count)
    }


    private func decodePacket(_ reader: inout OSCReader, limit: Int) throws -> OSCPacket {
        guard let first = reader.peek() else {
            throw OSCDecodingError.unexpectedEnd(
                offset: reader.offset, needed: 1, available: 0
            )
        }

        switch first {
        case UInt8(ascii: "#"):
            return .bundle(try decodeBundle(&reader, limit: limit))
        case UInt8(ascii: "/"):
            return .message(try decodeMessage(&reader, limit: limit))
        default:
            throw OSCDecodingError.notAPacket(offset: reader.offset, firstByte: first)
        }
    }


    private func decodeBundle(_ reader: inout OSCReader, limit: Int) throws -> OSCBundle {
        let identifierOffset = reader.offset
        let identifier = try reader.readString(limit: limit)
        guard identifier == OSCBundle.identifier else {
            throw OSCDecodingError.invalidBundleIdentifier(offset: identifierOffset)
        }

        let timeTag = OSCTimeTag(rawValue: try reader.readUInt64(limit: limit))

        var elements: [OSCPacket] = []
        while reader.offset < limit {
            let sizeOffset = reader.offset
            let declaredSize = try reader.readInt32(limit: limit)

            guard declaredSize >= 0 else {
                throw OSCDecodingError.negativeSize(offset: sizeOffset, declared: declaredSize)
            }

            let remaining = limit - reader.offset
            guard Int(declaredSize) <= remaining else {
                throw OSCDecodingError.bundleElementOverrunsBuffer(
                    offset: sizeOffset, declared: Int(declaredSize), remaining: remaining
                )
            }

            guard declaredSize > 0 else { continue }

            let elementLimit = reader.offset + Int(declaredSize)
            elements.append(try decodePacket(&reader, limit: elementLimit))

            reader.seek(to: elementLimit)
        }

        return OSCBundle(timeTag: timeTag, elements: elements)
    }


    private func decodeMessage(_ reader: inout OSCReader, limit: Int) throws -> OSCMessage {
        let addressOffset = reader.offset
        let address = try reader.readString(limit: limit)
        guard address.hasPrefix("/") else {
            throw OSCDecodingError.invalidAddress(offset: addressOffset, address: address)
        }

        guard reader.offset < limit else {
            return OSCMessage(address)
        }

        let typeTagOffset = reader.offset
        let typeTagString = try reader.readString(limit: limit)
        guard typeTagString.hasPrefix(",") else {
            throw OSCDecodingError.malformedTypeTagString(offset: typeTagOffset)
        }

        var arguments: [OSCValue] = []
        arguments.reserveCapacity(typeTagString.count - 1)
        for tag in typeTagString.dropFirst() {
            arguments.append(try decodeArgument(tag: tag, from: &reader, limit: limit))
        }

        return OSCMessage(address, arguments)
    }

    private func decodeArgument(
        tag: Character,
        from reader: inout OSCReader,
        limit: Int
    ) throws -> OSCValue {
        let tagOffset = reader.offset
        switch tag {
        case "i":
            return .int32(try reader.readInt32(limit: limit))
        case "f":
            return .float32(Float(bitPattern: try reader.readUInt32(limit: limit)))
        case "s":
            return .string(try reader.readString(limit: limit))
        case "S":
            return .symbol(try reader.readString(limit: limit))
        case "b":
            return .blob(try reader.readBlob(limit: limit))
        case "h":
            return .int64(try reader.readInt64(limit: limit))
        case "d":
            return .double(Double(bitPattern: try reader.readUInt64(limit: limit)))
        case "t":
            return .timeTag(OSCTimeTag(rawValue: try reader.readUInt64(limit: limit)))
        case "T":
            return .true
        case "F":
            return .false
        case "N":
            return .null
        case "I":
            return .impulse
        default:
            throw OSCDecodingError.unknownTypeTag(offset: tagOffset, tag: tag)
        }
    }
}


nonisolated private struct OSCReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int { bytes.count }

    func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    mutating func seek(to newOffset: Int) {
        offset = min(newOffset, bytes.count)
    }

    private mutating func require(_ needed: Int, limit: Int) throws {
        let available = limit - offset
        guard needed <= available, offset + needed <= bytes.count else {
            throw OSCDecodingError.unexpectedEnd(
                offset: offset, needed: needed, available: max(0, available)
            )
        }
    }

    mutating func readUInt32(limit: Int) throws -> UInt32 {
        try require(4, limit: limit)
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    mutating func readInt32(limit: Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(limit: limit))
    }

    mutating func readUInt64(limit: Int) throws -> UInt64 {
        let high = try readUInt32(limit: limit)
        let low = try readUInt32(limit: limit)
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func readInt64(limit: Int) throws -> Int64 {
        Int64(bitPattern: try readUInt64(limit: limit))
    }

    mutating func readString(limit: Int) throws -> String {
        let start = offset
        var terminator = offset
        while terminator < limit, terminator < bytes.count, bytes[terminator] != 0 {
            terminator += 1
        }
        guard terminator < limit, terminator < bytes.count else {
            throw OSCDecodingError.unterminatedString(offset: start)
        }

        let length = terminator - start
        guard let string = String(bytes: bytes[start..<terminator], encoding: .utf8) else {
            throw OSCDecodingError.invalidUTF8(offset: start)
        }

        let padded = (length / OSCEncoder.alignment + 1) * OSCEncoder.alignment
        offset = min(start + padded, min(limit, bytes.count))
        return string
    }

    mutating func readBlob(limit: Int) throws -> Data {
        let sizeOffset = offset
        let declaredSize = try readInt32(limit: limit)

        guard declaredSize >= 0 else {
            throw OSCDecodingError.negativeSize(offset: sizeOffset, declared: declaredSize)
        }

        let remaining = limit - offset
        guard Int(declaredSize) <= remaining else {
            throw OSCDecodingError.blobOverrunsBuffer(
                offset: sizeOffset, declared: Int(declaredSize), remaining: remaining
            )
        }

        let start = offset
        let end = start + Int(declaredSize)
        let blob = Data(bytes[start..<end])

        let remainderBytes = Int(declaredSize) % OSCEncoder.alignment
        let padding = remainderBytes == 0 ? 0 : OSCEncoder.alignment - remainderBytes
        offset = min(end + padding, min(limit, bytes.count))
        return blob
    }
}
