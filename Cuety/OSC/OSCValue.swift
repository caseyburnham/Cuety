import Foundation

/// An OSC time tag in NTP format: the high 32 bits are seconds since
/// 1900-01-01, the low 32 bits are a binary fraction of a second.
nonisolated struct OSCTimeTag: Hashable, Sendable {
    /// Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
    private static let ntpToUnixOffset: TimeInterval = 2_208_988_800

    var rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The special value meaning "act on this immediately", defined by the
    /// OSC spec as the time tag whose only set bit is the least significant.
    static let immediate = OSCTimeTag(rawValue: 1)

    var isImmediate: Bool { rawValue == 1 }

    init(date: Date) {
        let ntpSeconds = date.timeIntervalSince1970 + Self.ntpToUnixOffset
        // Negative NTP seconds cannot be represented; clamp rather than trap,
        // since a bad clock shouldn't be able to crash the app.
        guard ntpSeconds > 0 else {
            self.rawValue = 0
            return
        }
        let whole = UInt64(ntpSeconds.rounded(.down))
        let fraction = ntpSeconds - Double(whole)
        let fractionBits = UInt64(fraction * Double(1 << 32))
        self.rawValue = (whole << 32) | (fractionBits & 0xFFFF_FFFF)
    }

    /// `nil` for ``immediate``, which denotes "now" rather than a fixed instant.
    var date: Date? {
        guard !isImmediate else { return nil }
        let whole = Double(rawValue >> 32)
        let fraction = Double(rawValue & 0xFFFF_FFFF) / Double(1 << 32)
        return Date(timeIntervalSince1970: whole + fraction - Self.ntpToUnixOffset)
    }
}

/// A single OSC argument.
///
/// The cases cover the OSC 1.0 required types, the optional types QLab uses,
/// and the four zero-width tag-only types.
nonisolated enum OSCValue: Hashable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timeTag(OSCTimeTag)
    /// An alternate string type (`S`). Semantically a string; kept distinct so
    /// a decoded message re-encodes to the same bytes it arrived as.
    case symbol(String)
    case `true`
    case `false`
    case null
    case impulse

    /// The OSC type tag character that represents this value on the wire.
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

    /// Type tags that carry no payload bytes — the value lives entirely in the tag.
    static let zeroWidthTags: Set<Character> = ["T", "F", "N", "I"]
}

// MARK: - Convenience accessors
//
// QLab replies arrive as a single string argument, and many commands take one
// number, so these keep call sites free of `case let` pattern matching.

nonisolated extension OSCValue {
    /// The value as a string, for the string-like cases only.
    var stringValue: String? {
        switch self {
        case .string(let value), .symbol(let value): value
        default: nil
        }
    }

    /// The value as a `Double`, for any numeric case.
    var doubleValue: Double? {
        switch self {
        case .int32(let value): Double(value)
        case .float32(let value): Double(value)
        case .int64(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// The value as an `Int`, for any integral case.
    var intValue: Int? {
        switch self {
        case .int32(let value): Int(value)
        case .int64(let value): Int(value)
        case .float32(let value): Int(value)
        case .double(let value): Int(value)
        default: nil
        }
    }

    /// The value as a `Bool`, accepting both the tag-only booleans and the
    /// numeric 0/1 form that OSC senders commonly use instead.
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

// MARK: - Literal conveniences

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
