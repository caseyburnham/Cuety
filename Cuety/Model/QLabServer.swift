import Foundation
import Network

nonisolated struct QLabServer: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case bonjour
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
    var endpoint: NWEndpoint
    var workspaces: [QLabWorkspaceInfo] = []
    var lastError: String?
    var hasBeenProbed = false

    var address: String? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        return "\(host):\(port.rawValue)"
    }

    static let defaultPort: UInt16 = 53000

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


    static func identity(host: String, port: UInt16) -> String {
        let normalized = normalizedHost(host)
        return "\(isThisMac(normalized) ? "localhost" : normalized):\(port)"
    }

    static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func isThisMac(_ normalizedHost: String) -> Bool {
        localhostAliases.contains(normalizedHost)
    }

    private static let localhostAliases: Set<String> = {
        var aliases: Set<String> = [
            "localhost",
            "127.0.0.1",
            "::1",
            "0:0:0:0:0:0:0:1",
            "0000:0000:0000:0000:0000:0000:0000:0001",
        ]

        for name in [Host.current().localizedName, ProcessInfo.processInfo.hostName] {
            guard let name else { continue }
            let normalized = normalizedHost(name)
            guard !normalized.isEmpty else { continue }
            aliases.insert(normalized)
            if normalized.hasSuffix(".local") {
                aliases.insert(String(normalized.dropLast(".local".count)))
            }
        }

        return aliases
    }()
}

nonisolated struct WorkspaceSelection: Hashable, Sendable {
    let serverID: String
    let workspaceID: String
}
