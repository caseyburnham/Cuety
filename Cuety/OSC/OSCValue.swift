import Foundation

/// OSC time tags use the NTP epoch and reserve raw value `1` for immediate execution.

nonisolated struct OSCTimeTag: Hashable, Sendable {
    private static let ntpToUnixOffset: TimeInterval = 2_208_988_800

    var rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let immediate = OSCTimeTag(rawValue: 1)

    var isImmediate: Bool { rawValue == 1 }

    init(date: Date) {
        let ntpSeconds = date.timeIntervalSince1970 + Self.ntpToUnixOffset
        guard ntpSeconds > 0 else {
            self.rawValue = 0
            return
        }
        let whole = UInt64(ntpSeconds.rounded(.down))
        let fraction = ntpSeconds - Double(whole)
        let fractionBits = UInt64(fraction * Double(1 << 32))
        self.rawValue = (whole << 32) | (fractionBits & 0xFFFF_FFFF)
    }

    var date: Date? {
        guard !isImmediate else { return nil }
        let whole = Double(rawValue >> 32)
        let fraction = Double(rawValue & 0xFFFF_FFFF) / Double(1 << 32)
        return Date(timeIntervalSince1970: whole + fraction - Self.ntpToUnixOffset)
    }
}

nonisolated enum OSCValue: Hashable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timeTag(OSCTimeTag)
    case symbol(String)
    case `true`
    case `false`
    case null
    case impulse

    var typeTag: Character {
        switch self {
        case .int32: "i"
        case .float32: "f"
        case .string: "s"
        case .blob: "b"
        case .int64: "h"
        case .double: "d"
        case .timeTag: "t"
        case .symbol: "S"
        case .true: "T"
        case .false: "F"
        case .null: "N"
        case .impulse: "I"
        }
    }

    static let zeroWidthTags: Set<Character> = ["T", "F", "N", "I"]
}


nonisolated extension OSCValue {
    var stringValue: String? {
        switch self {
        case .string(let value), .symbol(let value): value
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int32(let value): Double(value)
        case .float32(let value): Double(value)
        case .int64(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int32(let value): Int(value)
        case .int64(let value): Int(value)
        case .float32(let value): Int(value)
        case .double(let value): Int(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .true: true
        case .false: false
        case .int32(let value): value != 0
        case .int64(let value): value != 0
        default: nil
        }
    }

    var blobValue: Data? {
        switch self {
        case .blob(let data): data
        default: nil
        }
    }
}


nonisolated extension OSCValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

nonisolated extension OSCValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int32) {
        self = .int32(value)
    }
}

nonisolated extension OSCValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Float) {
        self = .float32(value)
    }
}

nonisolated extension OSCValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = value ? .true : .false
    }
}
