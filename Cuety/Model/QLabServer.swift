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
            id: "localhost:\(port)",
            name: "This Mac",
            source: .manual,
            endpoint: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 53000)
            )
        )
    }

    /// Builds a manual entry from a user-supplied host and port.
    static func manual(host: String, port: UInt16) -> QLabServer {
        QLabServer(
            id: "\(host):\(port)",
            name: host,
            source: .manual,
            endpoint: .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 53000)
            )
        )
    }

    /// Builds an entry from a Bonjour browse result.
    static func bonjour(endpoint: NWEndpoint) -> QLabServer? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        return QLabServer(
            id: "bonjour:\(name)",
            name: name,
            source: .bonjour,
            endpoint: endpoint
        )
    }
}

/// Identifies one workspace on one server — what the sidebar selects and what
/// the client connects to.
nonisolated struct WorkspaceSelection: Hashable, Sendable {
    let serverID: String
    let workspaceID: String
}
