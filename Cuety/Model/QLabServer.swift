import Foundation
import Network

/// A machine running QLab, either discovered via Bonjour or added by hand.
nonisolated struct QLabServer: Identifiable, Hashable, Sendable {
    /// How Cuety learned about this server, which drives the sidebar grouping.
    enum Source: Hashable, Sendable {
        /// Discovered by browsing `_qlab._tcp`.
        case bonjour
        /// Typed in by the user, or the built-in localhost entry.
        case manual

        var sectionTitle: String {
            switch self {
            case .bonjour: "Bonjour"
            case .manual: "Local"
            }
        }
    }

    /// The canonical identity of the machine and port this entry points at.
    ///
    /// Two entries with the same `id` are the same server, however the
    /// operator spelled it or however Cuety found it — see
    /// ``identity(host:port:)``. Deliberately separate from ``name``, which is
    /// only what the row says.
    ///
    /// The spelling of this string is load-bearing beyond the sidebar:
    /// ``WorkspaceSelection/serverID`` carries it, and `lastServerID` persists
    /// it. `127.0.0.1:53000` therefore canonicalises to `localhost:53000` —
    /// the form the built-in entry has always used — so an existing remembered
    /// workspace still matches after this change.
    let id: String
    var name: String
    var source: Source
    /// The endpoint to connect to. For Bonjour servers this is a `.service`
    /// endpoint, so the system resolves it — Cuety never does its own DNS-SD.
    var endpoint: NWEndpoint
    /// Workspaces reported by `/workspaces`, once we've asked.
    var workspaces: [QLabWorkspaceInfo] = []
    /// Set when a `/workspaces` query against this server failed.
    var lastError: String?
    /// True once a `/workspaces` query has finished against this server, however
    /// it turned out. Separates "nothing open" from "we haven't asked" — which
    /// the sidebar must not conflate now that some servers go unprobed at launch.
    var hasBeenProbed = false

    /// A host:port description, when one is knowable.
    ///
    /// `nil` for a Bonjour service: the system resolves its address at connect
    /// time, so Cuety has nothing truthful to report — and the service name is
    /// already the row's title, so repeating it would say nothing.
    var address: String? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        return "\(host):\(port.rawValue)"
    }

    /// The standard QLab OSC port.
    static let defaultPort: UInt16 = 53000

    /// The always-present entry for QLab running on this Mac.
    static func localhost(port: UInt16 = QLabServer.defaultPort) -> QLabServer {
        QLabServer(
            id: identity(host: "127.0.0.1", port: port),
            name: "This Mac",
            source: .manual,
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 53000)
            )
        )
    }

    /// Builds a manual entry from a user-supplied host and port.
    ///
    /// The identity is canonical; the name is what the operator typed, so the
    /// sidebar still shows them their own spelling.
    static func manual(host: String, port: UInt16) -> QLabServer {
        let typed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return QLabServer(
            id: identity(host: typed, port: port),
            name: typed,
            source: .manual,
            endpoint: .hostPort(
                host: NWEndpoint.Host(typed),
                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 53000)
            )
        )
    }

    /// Builds an entry from a Bonjour browse result.
    ///
    /// A service cannot be reduced to a host and port without resolving it,
    /// which Cuety deliberately leaves to the system at connect time — so a
    /// discovered server is identified by its service name, case-folded. The
    /// one case worth collapsing is *this* Mac advertising itself, which is
    /// recognised and given the built-in entry's identity so the sidebar shows
    /// one "This Mac" rather than two rows for the machine the operator is
    /// sitting at.
    ///
    /// Known limit, recorded rather than papered over: a *remote* machine
    /// discovered by Bonjour and also added by hand as an IP address will
    /// appear twice. Recognising those as one thing needs address resolution
    /// Cuety does not do.
    static func bonjour(endpoint: NWEndpoint) -> QLabServer? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let normalized = normalizedHost(name)
        return QLabServer(
            id: isThisMac(normalized)
                ? identity(host: "127.0.0.1", port: defaultPort)
                : "bonjour:\(normalized)",
            name: name,
            source: .bonjour,
            endpoint: endpoint
        )
    }

    // MARK: - Identity

    /// The canonical identity for a host and port.
    ///
    /// Spelling is not identity. Case, surrounding whitespace, the DNS root
    /// dot, and IPv6 brackets are all folded away, and every way of naming the
    /// machine Cuety is running on collapses onto one token — which is what
    /// stops `127.0.0.1` and "This Mac" being two rows for one QLab, and what
    /// made four stale `127.0.0.1` entries able to accumulate in the first
    /// place.
    ///
    /// The port is part of the identity: two QLab instances on one machine are
    /// genuinely two servers.
    static func identity(host: String, port: UInt16) -> String {
        let normalized = normalizedHost(host)
        return "\(isThisMac(normalized) ? "localhost" : normalized):\(port)"
    }

    /// Folds a host into a comparable form.
    static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `[::1]` and `::1` are the same address, bracketed for a URL.
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        // A trailing dot is the DNS root and carries no meaning here.
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// Whether an already-normalized host names the machine Cuety runs on.
    private static func isThisMac(_ normalizedHost: String) -> Bool {
        localhostAliases.contains(normalizedHost)
    }

    /// Every spelling of "the machine Cuety is running on".
    ///
    /// Computed once: `Host.current()` and `ProcessInfo` both touch system
    /// configuration, and this is consulted for every server on every refresh.
    private static let localhostAliases: Set<String> = {
        var aliases: Set<String> = [
            "localhost",
            "127.0.0.1",
            "::1",
            "0:0:0:0:0:0:0:1",
            "0000:0000:0000:0000:0000:0000:0000:0001",
        ]

        // This Mac's own names, so its Bonjour advertisement and a manual
        // entry by hostname both land on the built-in entry. Bonjour service
        // names use the sharing name ("Casey's Mac"); `hostName` gives the
        // DNS form ("caseys-mac.local").
        for name in [Host.current().localizedName, ProcessInfo.processInfo.hostName] {
            guard let name else { continue }
            let normalized = normalizedHost(name)
            guard !normalized.isEmpty else { continue }
            aliases.insert(normalized)
            // Both `caseys-mac.local` and `caseys-mac` reach this machine.
            if normalized.hasSuffix(".local") {
                aliases.insert(String(normalized.dropLast(".local".count)))
            }
        }

        return aliases
    }()
}

/// Identifies one workspace on one server — what the sidebar selects and what
/// the client connects to.
nonisolated struct WorkspaceSelection: Hashable, Sendable {
    let serverID: String
    let workspaceID: String
}
