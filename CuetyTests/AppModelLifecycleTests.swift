import Foundation
import Testing

@testable import Cuety

@Suite("App model lifecycle")
@MainActor
struct AppModelLifecycleTests {
    private func makeModel(
        autoConnect: Bool = false,
        lastWorkspace: WorkspaceSelection? = nil,
        requestTimeout: TimeInterval? = nil
    ) throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let preferences = Preferences(defaults: defaults)
        preferences.autoConnect = autoConnect
        preferences.lastWorkspace = lastWorkspace
        if let requestTimeout { preferences.requestTimeout = requestTimeout }
        return AppModel(preferences: preferences)
    }

    private static let unroutableHost = "192.0.2.1"
    private static let otherUnroutableHost = "192.0.2.2"

    @Test("Starting twice performs the launch sequence once")
    func startIsIdempotent() throws {
        let model = try makeModel()
        defer { model.startupTask?.cancel() }

        model.start()
        let first = try #require(model.startupTask)

        model.start()
        model.start()

        #expect(model.startupTask == first)
    }

    @Test("Disconnecting stops the launch reconnect")
    func disconnectCancelsAutoConnect() throws {
        let model = try makeModel(
            autoConnect: true,
            lastWorkspace: WorkspaceSelection(serverID: "S", workspaceID: "W")
        )

        model.start()
        let startup = try #require(model.startupTask)
        #expect(!startup.isCancelled)

        model.disconnect()

        #expect(startup.isCancelled)
    }

    @Test("With nothing connected, only Connect and Refresh are on offer")
    func idleAvailability() throws {
        let model = try makeModel()

        #expect(!model.canDisconnect)
        #expect(model.canConnect)
        #expect(model.canRefresh)
    }

    @Test("A refresh asks This Mac, like every other server")
    func refreshProbesThisMac() async throws {
        let model = try makeModel()
        let localhostID = QLabServer.localhost().id

        try #require(model.browser.server(withID: localhostID)?.hasBeenProbed == false)

        await model.refresh()

        #expect(model.browser.server(withID: localhostID)?.hasBeenProbed == true)
    }

    @Test("A server that appears mid-refresh is probed by that refresh")
    func serversFoundMidRefreshAreProbed() async throws {
        let model = try makeModel(requestTimeout: 1)

        let blocking = model.browser.addManualServer(host: Self.unroutableHost, port: 53000)

        let refreshing = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(200))
        try #require(model.isRefreshing)

        let late = model.browser.addManualServer(
            host: Self.otherUnroutableHost, port: 53000
        )
        try #require(late.id != blocking.id)

        await refreshing.value

        #expect(model.browser.server(withID: late.id)?.hasBeenProbed == true)
        #expect(model.browser.server(withID: blocking.id)?.hasBeenProbed == true)
    }

    @Test("Refresh stays available while a refresh is running")
    func refreshIsNotLockedOutByItself() throws {
        let model = try makeModel()

        let refreshing = Task { await model.refresh() }
        defer { refreshing.cancel() }

        #expect(model.canRefresh)
    }

    @Test("A cancelled launch sequence is not restarted by a later start")
    func cancellationIsNotUndoneByAnotherStart() throws {
        let model = try makeModel(
            autoConnect: true,
            lastWorkspace: WorkspaceSelection(serverID: "S", workspaceID: "W")
        )

        model.start()
        let startup = try #require(model.startupTask)
        model.disconnect()

        model.start()

        #expect(model.startupTask == startup)
        #expect(startup.isCancelled)
    }


    @Test("Leaving presentation mode restores the sidebar it collapsed")
    func presentationRestoresTheSidebar() throws {
        let model = try makeModel()
        model.isSidebarVisible = true

        model.togglePresentationMode()
        #expect(model.isPresenting)
        #expect(!model.isSidebarVisible)

        model.togglePresentationMode()
        #expect(!model.isPresenting)
        #expect(model.isSidebarVisible)
    }

    @Test("A sidebar collapsed before presenting stays collapsed afterwards")
    func presentationRestoresACollapsedSidebar() throws {
        let model = try makeModel()
        model.isSidebarVisible = false

        model.togglePresentationMode()
        model.togglePresentationMode()

        #expect(!model.isSidebarVisible)
    }

    @Test("A window already presenting does not overwrite the sidebar to restore")
    func redundantPresentingIsIgnored() throws {
        let model = try makeModel()
        model.isSidebarVisible = true

        model.setPresenting(true)
        model.setPresenting(true)
        model.setPresenting(false)

        #expect(model.isSidebarVisible)
    }
}
