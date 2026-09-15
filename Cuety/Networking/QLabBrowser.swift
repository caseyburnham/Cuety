import Foundation
import Network
import os

/// QLab advertises Bonjour services as `_qlab._tcp`; `.service` endpoints are resolved by Network.

@Observable
@MainActor
final class QLabBrowser {
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "QLabBrowser")
    private static let persistenceLogger = Logger(
        subsystem: "com.ivxx.Cuety",
        category: "QLabBrowser.Persistence"
    )

    static let serviceType = "_qlab._tcp"

    private(set) var servers: [QLabServer] = []

    private(set) var browseError: String?

    var onServerDiscovered: ((QLabServer) -> Void)?

    private var browser: NWBrowser?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = [QLabServer.localhost()] + Self.loadManualServers(from: defaults)
    }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleStateChange(state) }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results: results) }
        }

        browser.start(queue: .main)
    }

    func restartBrowsing() {
        stop()
        start()
    }

    private func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func handleStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            browseError = nil
        case .failed(let error):
            logger.error("Browse failed: \(error.operatorDescription, privacy: .public)")
            browseError = error.operatorDescription
            stop()
        case .waiting(let error):
            browseError = error.operatorDescription
        default:
            break
        }
    }

    private func apply(results: Set<NWBrowser.Result>) {
        let discovered = results
            .compactMap { QLabServer.bonjour(endpoint: $0.endpoint) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let existing = Dictionary(
            servers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var merged: [QLabServer] = []
        var seen: Set<String> = []

        for server in servers where server.source == .manual {
            guard seen.insert(server.id).inserted else { continue }
            merged.append(server)
        }

        for server in discovered {
            guard seen.insert(server.id).inserted else { continue }
            var server = server
            if let known = existing[server.id] {
                server.workspaces = known.workspaces
                server.lastError = known.lastError
                server.hasBeenProbed = known.hasBeenProbed
            }
            merged.append(server)
        }

        servers = merged

        for server in discovered where existing[server.id] == nil {
            onServerDiscovered?(server)
        }
    }

    @discardableResult
    func addManualServer(host: String, port: UInt16) -> QLabServer {
        let server = QLabServer.manual(host: host, port: port)
        if let existing = servers.first(where: { $0.id == server.id }) {
            return existing
        }
        servers.append(server)
        persistManualServers()
        return server
    }

    func removeManualServer(id: String) {
        guard id != QLabServer.localhost().id else { return }
        servers.removeAll { $0.id == id && $0.source == .manual }
        persistManualServers()
    }

    func update(_ server: QLabServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
    }

    func server(withID id: String) -> QLabServer? {
        servers.first { $0.id == id }
    }

    var bonjourServers: [QLabServer] { servers.filter { $0.source == .bonjour } }

    var manualServers: [QLabServer] { servers.filter { $0.source == .manual } }

    var orderedServers: [QLabServer] { manualServers + bonjourServers }

    private struct StoredServer: Codable {
        let host: String
        let port: UInt16
    }

    private static let manualServersKey = "manualServers"

    private static func loadManualServers(from defaults: UserDefaults) -> [QLabServer] {
        guard let data = defaults.data(forKey: manualServersKey) else { return [] }

        let stored: [StoredServer]
        do {
            stored = try JSONDecoder().decode([StoredServer].self, from: data)
        } catch {
            persistenceLogger.warning(
                "Ignoring malformed manual server preferences: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }

        let localhostID = QLabServer.localhost().id
        return stored
            .map { QLabServer.manual(host: $0.host, port: $0.port) }
            .filter { $0.id != localhostID }
    }

    private func persistManualServers() {
        let localhostID = QLabServer.localhost().id
        let stored: [StoredServer] = servers.compactMap { server in
            guard server.source == .manual, server.id != localhostID else { return nil }
            guard case .hostPort(let host, let port) = server.endpoint else { return nil }
            return StoredServer(host: "\(host)", port: port.rawValue)
        }
        do {
            defaults.set(
                try JSONEncoder().encode(stored),
                forKey: Self.manualServersKey
            )
        } catch {
            logger.warning(
                "Could not persist manual server preferences: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
