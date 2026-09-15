import Foundation

nonisolated enum OSCRedaction {
    static let placeholder = "••••"

    static func redacting(_ message: OSCMessage) -> OSCMessage {
        guard !message.arguments.isEmpty, carriesCredential(message) else { return message }
        var redacted = message
        redacted.arguments = message.arguments.map { _ in .string(placeholder) }
        return redacted
    }

    private static func carriesCredential(_ message: OSCMessage) -> Bool {
        let components = message.addressComponents
        return components.count >= 3
            && components[0] == "workspace"
            && components.last == "connect"
    }
}
