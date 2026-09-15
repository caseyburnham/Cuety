import Foundation
import Network
import os

/// Discovers QLab instances on the local network and tracks manually added ones.
///
/// Browsing is `NWBrowser` against `_qlab._tcp` — the service type QLab
/// advertises. Cuety never resolves addresses itself: Bonjour servers keep a
/// `.service` endpoint so the system handles resolution at connect time, which
/// is both more robust and less code than doing DNS-SD by hand.
@Observable
@MainActor
final class QLabBrowser {
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "QLabBrowser")

    /// QLab's Bonjour service type.
    static let serviceType = "_qlab._tcp"

    /// Discovered and manual servers, Bonjour first within each section.
    private(set) var servers: [QLabServer] = []

    /// Set when browsing itself fails, e.g. local network permission denied.
    private(set) var browseError: String?

    private var browser: NWBrowser?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = [QLabServer.localhost()] + Self.loadManualServers(from: defaults)
    }

    // MARK: - Browsing

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        // QLab is always on the local link; including peer-to-peer would only
        // widen the search for no benefit.
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

    /// Restarts Bonjour discovery without discarding the currently displayed servers.
    func restartBrowsing() {
        stop()
        start()
    }

    /// Private: nothing outside this class ends browsing. ``restartBrowsing()``
    /// is what a refresh asks for, and a failed browser tears itself down.
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
            logger.error("Browse failed: \(error.localizedDescription, privacy: .public)")
            browseError = error.localizedDescription
            // A failed browser never recovers on its own, so drop it — `start()`
            // will build a fresh one when something asks again.
            stop()
        case .waiting(let error):
            browseError = error.localizedDescription
        default:
            break
        }
    }

    private func apply(results: Set<NWBrowser.Result>) {
        let discovered = results
            .compactMap { QLabServer.bonjour(endpoint: $0.endpoint) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Preserve what we already know about servers that are still present,
        // so the sidebar doesn't flicker empty — or back to "not yet asked" —
        // when Bonjour reports a change unrelated to them.
        let existing = Dictionary(
            servers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Manual entries first, and they win on identity: "This Mac" is the
        // operator's own row and must not be displaced by the same machine
        // arriving over Bonjour. Deduplicating here rather than in the sidebar
        // is what makes one machine one row no matter how it was found — the
        // display used to filter discovered servers by comparing *names*,
        // which was a guess dressed up as identity.
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
    }

    // MARK: - Manual servers

    /// Adds a server by host and port. Returns the entry, existing or new.
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
        // The localhost entry is not removable: it costs nothing and is the
        // most common case.
        guard id != QLabServer.localhost().id else { return }
        servers.removeAll { $0.id == id && $0.source == .manual }
        persistManualServers()
    }

    /// Replaces a server entry, e.g. after fetching its workspaces.
    func update(_ server: QLabServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
    }

    func server(withID id: String) -> QLabServer? {
        servers.first { $0.id == id }
    }

    // MARK: - Grouping

    /// Discovered servers, with no filtering of its own.
    ///
    /// This used to exclude anything whose *name* matched a manual entry or
    /// one of this Mac's names, which was identity by string comparison in the
    /// display layer. ``apply(results:)`` now deduplicates on
    /// ``QLabServer/id``, so by the time a server reaches here it is already
    /// the only entry for its machine.
    var bonjourServers: [QLabServer] { servers.filter { $0.source == .bonjour } }

    var manualServers: [QLabServer] { servers.filter { $0.source == .manual } }

    /// Every server in the order the operator should see them: the machines
    /// they added by hand — This Mac included — before the ones Cuety found.
    ///
    /// Stated once, here, rather than as `manualServers + bonjourServers` at
    /// each display site. Two surfaces list servers — the sidebar and the
    /// Connection menus — and the order they are listed in is one decision.
    var orderedServers: [QLabServer] { manualServers + bonjourServers }

    // MARK: - Persistence

    private struct StoredServer: Codable {
        let host: String
        let port: UInt16
    }

    private static let manualServersKey = "manualServers"

    private static func loadManualServers(from defaults: UserDefaults) -> [QLabServer] {
        guard let data = defaults.data(forKey: manualServersKey),
              let stored = try? JSONDecoder().decode([StoredServer].self, from: data)
        else { return [] }

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
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.manualServersKey)
    }
}
