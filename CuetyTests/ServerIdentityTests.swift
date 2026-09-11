import Foundation
import Network
import Testing

@testable import Cuety

/// What makes two sidebar entries the same machine.
///
/// Spelling is not identity. Getting this wrong is what let four stale
/// `127.0.0.1` rows accumulate alongside "This Mac", each costing a full
/// request timeout on every refresh.
@Suite("Server identity")
@MainActor
struct ServerIdentityTests {
    private let port = QLabServer.defaultPort

    @Test("Every spelling of this Mac is one server", arguments: [
        "localhost",
        "LOCALHOST",
        "localhost.",
        "  localhost  ",
        "127.0.0.1",
        "::1",
        "[::1]",
        "0:0:0:0:0:0:0:1",
        "0000:0000:0000:0000:0000:0000:0000:0001",
    ])
    func localhostAliasesShareOneIdentity(host: String) {
        // The built-in entry's identity, which is also the spelling persisted
        // as `lastServerID` — so canonicalising must land on exactly this or
        // an existing remembered workspace stops matching.
        #expect(QLabServer.identity(host: host, port: port) == "localhost:\(port)")
        #expect(QLabServer.manual(host: host, port: port).id == QLabServer.localhost().id)
    }

    @Test("Case and the DNS root dot are spelling, not identity")
    func remoteHostsAreFolded() {
        let canonical = QLabServer.identity(host: "qlab-mac.local", port: port)

        #expect(QLabServer.identity(host: "QLab-Mac.local", port: port) == canonical)
        #expect(QLabServer.identity(host: "qlab-mac.local.", port: port) == canonical)
        #expect(QLabServer.identity(host: " QLab-Mac.LOCAL. ", port: port) == canonical)
    }

    @Test("Two QLabs on one machine are two servers")
    func portIsPartOfIdentity() {
        // Not a spelling difference: QLab can run more than one instance, and
        // they are genuinely separate things to connect to.
        #expect(
            QLabServer.identity(host: "localhost", port: 53000)
                != QLabServer.identity(host: "localhost", port: 53001)
        )
        #expect(
            QLabServer.identity(host: "qlab-mac.local", port: 53000)
                != QLabServer.identity(host: "qlab-mac.local", port: 53001)
        )
    }

    @Test("Different machines stay different")
    func distinctHostsAreDistinct() {
        #expect(
            QLabServer.identity(host: "qlab-mac.local", port: port)
                != QLabServer.identity(host: "other-mac.local", port: port)
        )
        #expect(
            QLabServer.identity(host: "192.168.1.10", port: port)
                != QLabServer.identity(host: "192.168.1.11", port: port)
        )
    }

    @Test("A manual entry keeps the operator's own spelling as its name")
    func nameIsSeparateFromIdentity() {
        let server = QLabServer.manual(host: "QLab-Mac.Local", port: port)

        // Identity is canonical; the row still reads the way they typed it.
        #expect(server.id == QLabServer.identity(host: "qlab-mac.local", port: port))
        #expect(server.name == "QLab-Mac.Local")
    }

    @Test("Adding this Mac by address returns the entry that already exists")
    func addingLocalhostByAddressDoesNotDuplicate() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let browser = QLabBrowser(defaults: defaults)
        let before = browser.servers.count
        try #require(browser.server(withID: QLabServer.localhost().id) != nil)

        // The exact thing that produced four junk rows: `127.0.0.1:53000` used
        // to be a different identity from `localhost:53000`, so it was added
        // rather than recognised.
        let added = browser.addManualServer(host: "127.0.0.1", port: port)

        #expect(added.id == QLabServer.localhost().id)
        #expect(added.name == "This Mac")
        #expect(browser.servers.count == before)
    }

    @Test("Adding a genuinely new server still adds a row")
    func addingNewServerWorks() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let browser = QLabBrowser(defaults: defaults)
        let before = browser.servers.count

        let added = browser.addManualServer(host: "192.168.1.10", port: port)

        #expect(browser.servers.count == before + 1)
        #expect(browser.server(withID: added.id) != nil)
    }

    @Test("Adding the same server twice adds one row")
    func addingTwiceAddsOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let browser = QLabBrowser(defaults: defaults)
        let before = browser.servers.count

        let first = browser.addManualServer(host: "192.168.1.10", port: port)
        // Same machine, different spelling.
        let second = browser.addManualServer(host: "192.168.1.10.", port: port)

        #expect(first.id == second.id)
        #expect(browser.servers.count == before + 1)
    }

    /// Recorded so the deferral is deliberate: a remote machine found by
    /// Bonjour and also typed in as an IP address cannot be recognised as one
    /// thing without resolving the service, which Cuety leaves to the system
    /// at connect time.
    @Test("A discovered server is identified separately from a typed address")
    func remoteBonjourAndManualAreNotUnified() {
        let manual = QLabServer.manual(host: "192.168.1.10", port: port)
        let discovered = QLabServer.bonjour(
            endpoint: .service(
                name: "QLab Mac", type: QLabBrowser.serviceType, domain: "local.", interface: nil
            )
        )

        #expect(discovered?.id != manual.id)
    }
}
