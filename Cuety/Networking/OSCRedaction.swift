import Foundation

/// Which OSC arguments are credentials, and what stands in for them.
///
/// The Activity Log is retained for the length of a show, searchable,
/// inspectable, and copyable to the clipboard. A passcode that reaches it has
/// therefore been written down in four places at once, and the Keychain
/// guarding the operator's own copy does nothing whatsoever about that.
///
/// So redaction happens at *capture*, before an ``OSCEvent`` is constructed,
/// rather than at render time. Redacting on the way out would mean the secret
/// is still held in memory and still one forgotten surface away from being
/// shown — and there are three surfaces, one of which is the pasteboard.
/// A secret that was never stored cannot leak from a surface nobody updated.
///
/// The rule is deliberately narrow. An over-eager one that hid arguments Cuety
/// legitimately sends would make the log useless for the diagnosis it exists
/// for, which is the whole reason an operator opens it mid-show.
nonisolated enum OSCRedaction {
    /// What replaces a redacted argument.
    ///
    /// Bullets rather than an empty string, so the log still records that a
    /// passcode *was* sent — which is exactly the fact an operator debugging a
    /// refused connection needs.
    static let placeholder = "••••"

    /// A display-only copy of `message` with every credential argument
    /// replaced by ``placeholder``.
    ///
    /// Never send the result. The arguments no longer round-trip, and for a
    /// blob or a number the type itself has changed.
    static func redacting(_ message: OSCMessage) -> OSCMessage {
        guard !message.arguments.isEmpty, carriesCredential(message) else { return message }
        var redacted = message
        // Every argument, not just the first. A connect message carries
        // nothing but the passcode, so there is nothing here worth keeping and
        // a positional rule would be one QLab revision away from being wrong.
        redacted.arguments = message.arguments.map { _ in .string(placeholder) }
        return redacted
    }

    /// Whether a message carries a credential among its arguments.
    ///
    /// One address qualifies today:
    ///
    /// - `/workspace/<id>/connect`, whose single string argument is the
    ///   workspace passcode.
    ///
    /// Audited against every other message Cuety sends — `/workspaces`,
    /// `/forgetMeNot`, `/udpKeepAlive`, `/alwaysReply`, `/updates`,
    /// `/listen/playhead`, `/cueLists`, `/playbackPositionID`,
    /// `/valuesForKeys`, `/thump`, `/disconnect` — and none of them takes a
    /// secret. Nor does anything inbound: QLab's reply to `connect` answers
    /// with the access tier or `badpass`, and never echoes what was sent.
    ///
    /// QLab 4 also accepted the passcode as a trailing address component
    /// (`/workspace/<id>/connect/<passcode>`). Cuety has never sent that form,
    /// and redacting an address it does not build would be untested code
    /// guarding nothing — but if it ever does, this is the function that has
    /// to learn about it, and the address will need redacting as well as the
    /// arguments.
    private static func carriesCredential(_ message: OSCMessage) -> Bool {
        let components = message.addressComponents
        return components.count >= 3
            && components[0] == "workspace"
            && components.last == "connect"
    }
}
