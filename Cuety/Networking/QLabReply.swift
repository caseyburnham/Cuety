import Foundation

nonisolated enum QLabReplyStatus: Hashable, Sendable {
    case ok
    case error
    case denied
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "ok": self = .ok
        case "error": self = .error
        case "denied": self = .denied
        default: self = .unknown(rawValue)
        }
    }

    var isSuccess: Bool { self == .ok }
}

extension QLabReplyStatus: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }
}

nonisolated struct QLabReply<Payload: Decodable & Sendable>: Decodable, Sendable {
    let workspaceID: String?
    let address: String
    let status: QLabReplyStatus
    let data: Payload?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case address
        case status
        case data
    }
}

nonisolated struct QLabEmptyPayload: Decodable, Sendable {}

nonisolated enum QLabAccessLevel: Hashable, Sendable {
    case unspecified
    case view
    case control
    case edit
    case other(String)

    init?(connectReplyData: String) {
        let parts = connectReplyData.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard parts.first == "ok" else { return nil }

        guard parts.count == 2 else {
            self = .unspecified
            return
        }

        switch parts[1] {
        case "view": self = .view
        case "control": self = .control
        case "edit": self = .edit
        case let level: self = .other(String(level))
        }
    }

    var title: String {
        switch self {
        case .unspecified: "Granted"
        case .view: "View only"
        case .control: "Control"
        case .edit: "Edit"
        case .other(let level): level
        }
    }
}


nonisolated enum QLabReplyParser {
    enum Failure: Error, CustomStringConvertible {
        case notAReply(address: String)
        case missingJSONArgument(address: String)
        case malformedJSON(address: String, underlying: String)

        var description: String {
            switch self {
            case .notAReply(let address):
                "Message at \(address) is not a QLab reply."
            case .missingJSONArgument(let address):
                "Reply at \(address) carried no JSON string argument."
            case .malformedJSON(let address, let underlying):
                "Reply at \(address) contained JSON Cuety could not read: \(underlying)"
            }
        }
    }

    static let replyPrefix = "/reply"

    static func isReply(_ message: OSCMessage) -> Bool {
        message.address.hasPrefix(replyPrefix)
    }

    static func parse<Payload: Decodable & Sendable>(
        _ message: OSCMessage,
        as payloadType: Payload.Type
    ) throws -> QLabReply<Payload> {
        guard isReply(message) else {
            throw Failure.notAReply(address: message.address)
        }
        guard let json = message.arguments.first?.stringValue,
              let jsonData = json.data(using: .utf8)
        else {
            throw Failure.missingJSONArgument(address: message.address)
        }

        do {
            return try JSONDecoder().decode(QLabReply<Payload>.self, from: jsonData)
        } catch {
            throw Failure.malformedJSON(
                address: message.address,
                underlying: error.operatorDescription
            )
        }
    }

    static func correlationKey(for address: String) -> String {
        let parts = address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3, parts[1] == "workspace" else { return address }
        return "/" + parts.dropFirst(3).joined(separator: "/")
    }

    static func correlationAddress(of message: OSCMessage) -> String? {
        guard isReply(message),
              let json = message.arguments.first?.stringValue,
              let jsonData = json.data(using: .utf8)
        else { return nil }

        struct AddressOnly: Decodable { let address: String }
        if let envelope = try? JSONDecoder().decode(AddressOnly.self, from: jsonData) {
            return envelope.address
        }

        return String(message.address.dropFirst(replyPrefix.count))
    }
}
