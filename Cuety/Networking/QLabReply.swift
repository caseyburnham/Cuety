import Foundation

/// The status field of a QLab reply.
nonisolated enum QLabReplyStatus: Hashable, Sendable {
    case ok
    case error
    /// The client hasn't connected, or its passcode lacks the required privilege.
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

/// QLab's reply envelope, which arrives as a single JSON string argument on an
/// address beginning `/reply/`.
///
/// ```json
/// { "workspace_id": "...", "address": "/workspace/…", "status": "ok", "data": … }
/// ```
///
/// `data` is polymorphic, so the payload type is a generic parameter chosen by
/// whichever request is being awaited.
nonisolated struct QLabReply<Payload: Decodable & Sendable>: Decodable, Sendable {
    let workspaceID: String?
    /// The address of the message this is a reply to. This is the field used to
    /// correlate replies with pending requests, because it echoes the address
    /// exactly as sent — the `/reply/…` OSC address sometimes drops the
    /// workspace prefix.
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

/// A reply whose payload we don't care about, only its status.
nonisolated struct QLabEmptyPayload: Decodable, Sendable {}

/// The permission tier QLab grants a connection.
///
/// `/workspace/{id}/connect` answers with `ok` on its own, or with `ok:` and
/// the access level the passcode unlocked — `ok:view`, `ok:control`,
/// `ok:edit`. Both shapes mean the connection succeeded, so a bare `ok` is
/// treated as an unspecified level rather than as the only valid answer.
///
/// Cuety only ever reads, so the level is recorded for the inspector rather
/// than enforced: even `view` is enough to do everything Cuety does.
nonisolated enum QLabAccessLevel: Hashable, Sendable {
    /// QLab said only `ok`, naming no level.
    case unspecified
    case view
    case control
    case edit
    /// A level this version of Cuety doesn't recognise, kept verbatim so the
    /// inspector can still show what QLab actually said.
    case other(String)

    /// Reads the `data` field of a `/connect` reply.
    ///
    /// Returns `nil` when the reply is not an acceptance at all — `badpass`,
    /// an empty payload, or anything else the caller must handle as a failure.
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

// MARK: - Reply parsing

nonisolated enum QLabReplyParser {
    /// Errors raised while turning an OSC message into a typed reply.
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

    /// The prefix QLab puts on every reply address.
    static let replyPrefix = "/reply"

    static func isReply(_ message: OSCMessage) -> Bool {
        message.address.hasPrefix(replyPrefix)
    }

    /// Decodes a reply envelope with the given payload type.
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
                underlying: String(describing: error)
            )
        }
    }

    /// The form of an address used to match a reply to the request that sent it.
    ///
    /// QLab is inconsistent about whether a reply echoes the `/workspace/{id}`
    /// prefix: some replies carry it, some answer the bare address. Comparing
    /// raw strings therefore drops replies for no reason — the request then sits
    /// until it times out, and the caller sees silence rather than an answer.
    /// Reducing both sides to the un-prefixed form makes the match hold either
    /// way, and is why correlation runs on this rather than on the address as
    /// sent.
    static func correlationKey(for address: String) -> String {
        let parts = address.split(separator: "/", omittingEmptySubsequences: false)
        // A prefixed address splits as ["", "workspace", "<id>", …].
        guard parts.count > 3, parts[1] == "workspace" else { return address }
        return "/" + parts.dropFirst(3).joined(separator: "/")
    }

    /// Reads just the `address` field, without committing to a payload type.
    ///
    /// This is what request/reply correlation runs on: the dispatcher needs to
    /// know *which* request a reply belongs to before it knows how to decode
    /// the payload.
    static func correlationAddress(of message: OSCMessage) -> String? {
        guard isReply(message),
              let json = message.arguments.first?.stringValue,
              let jsonData = json.data(using: .utf8)
        else { return nil }

        struct AddressOnly: Decodable { let address: String }
        if let envelope = try? JSONDecoder().decode(AddressOnly.self, from: jsonData) {
            return envelope.address
        }

        // Fall back to the OSC address with the `/reply` prefix stripped, for a
        // reply whose JSON body is unreadable but whose address is still usable.
        return String(message.address.dropFirst(replyPrefix.count))
    }
}
