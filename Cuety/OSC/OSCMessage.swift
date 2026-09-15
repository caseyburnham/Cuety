import Foundation

/// An OSC address must begin with `/`; pattern characters remain valid for QLab dictionaries.

nonisolated struct OSCMessage: Hashable, Sendable {
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
    var addressComponents: [String] {
        address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    var isValidForSending: Bool {
        guard address.hasPrefix("/") else { return false }
        guard !address.unicodeScalars.contains(where: {
            $0 == "\0" || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return false }
        return true
    }
}

nonisolated extension OSCMessage: CustomStringConvertible {
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

nonisolated struct OSCBundle: Hashable, Sendable {
    static let identifier = "#bundle"

    var timeTag: OSCTimeTag
    var elements: [OSCPacket]

    init(timeTag: OSCTimeTag = .immediate, elements: [OSCPacket] = []) {
        self.timeTag = timeTag
        self.elements = elements
    }

    var flattenedMessages: [OSCMessage] {
        elements.flatMap { element in
            switch element {
            case .message(let message): [message]
            case .bundle(let bundle): bundle.flattenedMessages
            }
        }
    }
}

nonisolated enum OSCPacket: Hashable, Sendable {
    case message(OSCMessage)
    case bundle(OSCBundle)

    var flattenedMessages: [OSCMessage] {
        switch self {
        case .message(let message): [message]
        case .bundle(let bundle): bundle.flattenedMessages
        }
    }
}
