import Foundation
import Network
import Testing

@testable import Cuety

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

        #expect(server.id == QLabServer.identity(host: "qlab-mac.local", port: port))
        #expect(server.name == "QLab-Mac.Local")
    }

    @Test("Adding this Mac by address returns the entry that already exists")
    func addingLocalhostByAddressDoesNotDuplicate() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let browser = QLabBrowser(defaults: defaults)
        let before = browser.servers.count
        try #require(browser.server(withID: QLabServer.localhost().id) != nil)

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
        let second = browser.addManualServer(host: "192.168.1.10.", port: port)

        #expect(first.id == second.id)
        #expect(browser.servers.count == before + 1)
    }

#if os(macOS)
    @Test("The name this Mac advertises over Bonjour is not a second machine")
    func advertisedComputerNameIsThisMac() throws {
        // QLab advertises the user-visible computer name ("Casey's MacBook Pro"),
        // not the DNS host name ("caseys-macbook-pro.local").
        let computerName = try #require(Host.current().localizedName)
        let discovered = try #require(QLabServer.bonjour(
            endpoint: .service(
                name: computerName,
                type: QLabBrowser.serviceType,
                domain: "local.",
                interface: nil
            )
        ))

        #expect(discovered.id == QLabServer.localhost().id)
    }
#endif

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


    private func model() throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        return AppModel(preferences: Preferences(defaults: defaults))
    }

    @Test("Only servers the operator added are theirs to remove")
    func removabilityIsLimitedToAddedServers() throws {
        let model = try model()

        let discovered = try #require(QLabServer.bonjour(
            endpoint: .service(
                name: "QLab Mac", type: QLabBrowser.serviceType, domain: "local.", interface: nil
            )
        ))
        #expect(model.canRemove(discovered) == false)

        #expect(model.canRemove(QLabServer.localhost()) == false)

        #expect(model.canRemove(model.browser.addManualServer(host: "192.168.1.10", port: port)))
    }

    @Test("A removed server stays removed across a relaunch")
    func removalIsPersisted() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = AppModel(preferences: Preferences(defaults: defaults))
        let added = model.browser.addManualServer(host: "192.168.1.10", port: port)
        try #require(model.browser.server(withID: added.id) != nil)

        model.removeServer(withID: added.id)

        #expect(model.browser.server(withID: added.id) == nil)
        #expect(QLabBrowser(defaults: defaults).server(withID: added.id) == nil)
    }

    @Test("Removing the server in use ends the session first")
    func removingTheSelectedServerDisconnects() throws {
        let model = try model()
        let added = model.browser.addManualServer(host: "192.168.1.10", port: port)
        model.selection = WorkspaceSelection(serverID: added.id, workspaceID: "W1")

        model.removeServer(withID: added.id)

        #expect(model.selection == nil)
        #expect(model.browser.server(withID: added.id) == nil)
    }

    @Test("Removing an unrelated server leaves the session alone")
    func removingAnotherServerKeepsTheSession() throws {
        let model = try model()
        let inUse = model.browser.addManualServer(host: "192.168.1.10", port: port)
        let other = model.browser.addManualServer(host: "192.168.1.11", port: port)
        let selection = WorkspaceSelection(serverID: inUse.id, workspaceID: "W1")
        model.selection = selection

        model.removeServer(withID: other.id)

        #expect(model.selection == selection)
        #expect(model.browser.server(withID: inUse.id) != nil)
    }

    @Test("This Mac cannot be removed even by identifier")
    func localhostSurvivesRemoval() throws {
        let model = try model()
        let localhostID = QLabServer.localhost().id

        model.removeServer(withID: localhostID)

        #expect(model.browser.server(withID: localhostID) != nil)
    }
}
