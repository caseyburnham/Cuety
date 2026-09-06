import Foundation

/// An OSC message: an address pattern plus zero or more arguments.
nonisolated struct OSCMessage: Hashable, Sendable {
    /// The OSC address pattern, always beginning with `/`.
    var address: String
    var arguments: [OSCValue]

    init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }

    init(_ address: String, _ arguments: OSCValue...) {
        self.init(address, arguments)
    }
}

nonisolated extension OSCMessage {
    /// The address split into its parts, with the leading slash removed.
    ///
    /// `"/update/workspace/ABC/cueList/DEF/playbackPosition"` becomes
    /// `["update", "workspace", "ABC", "cueList", "DEF", "playbackPosition"]`.
    var addressComponents: [String] {
        address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether the address is well-formed enough to send.
    ///
    /// Outgoing addresses are held to a stricter standard than incoming ones:
    /// a leading slash, no whitespace, and no embedded nulls. Pattern
    /// characters (`*`, `?`, `[]`, `{}`) are allowed, because QLab's dictionary
    /// uses them — `/cue/*/stop` is a legitimate address to send.
    var isValidForSending: Bool {
        guard address.hasPrefix("/") else { return false }
        guard !address.unicodeScalars.contains(where: {
            $0 == "\0" || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return false }
        return true
    }
}

nonisolated extension OSCMessage: CustomStringConvertible {
    /// A single-line rendering used by the Activity Log and by log messages.
    var description: String {
        guard !arguments.isEmpty else { return address }
        let rendered = arguments.map { value -> String in
            switch value {
            case .int32(let v): String(v)
            case .int64(let v): String(v)
            case .float32(let v): String(v)
            case .double(let v): String(v)
            case .string(let v), .symbol(let v): "\"\(v)\""
            case .blob(let data): "<\(data.count) bytes>"
            case .timeTag(let tag): tag.isImmediate ? "immediate" : String(tag.rawValue)
            case .true: "true"
            case .false: "false"
            case .null: "nil"
            case .impulse: "impulse"
            }
        }
        return "\(address) \(rendered.joined(separator: " "))"
    }
}

/// An OSC bundle: a time tag plus nested packets, which may themselves be bundles.
nonisolated struct OSCBundle: Hashable, Sendable {
    /// The literal that every bundle begins with on the wire.
    static let identifier = "#bundle"

    var timeTag: OSCTimeTag
    var elements: [OSCPacket]

    init(timeTag: OSCTimeTag = .immediate, elements: [OSCPacket] = []) {
        self.timeTag = timeTag
        self.elements = elements
    }

    /// Every message in the bundle, flattened depth-first through nested bundles.
    ///
    /// Cuety dispatches on messages, not bundles, so this is how an incoming
    /// bundle gets turned into work.
    var flattenedMessages: [OSCMessage] {
        elements.flatMap { element in
            switch element {
            case .message(let message): [message]
            case .bundle(let bundle): bundle.flattenedMessages
            }
        }
    }
}

/// Either of the two things an OSC packet can be.
nonisolated enum OSCPacket: Hashable, Sendable {
    case message(OSCMessage)
    case bundle(OSCBundle)

    /// Every message in the packet, flattened through any nested bundles.
    var flattenedMessages: [OSCMessage] {
        switch self {
        case .message(let message): [message]
        case .bundle(let bundle): bundle.flattenedMessages
        }
    }
}
