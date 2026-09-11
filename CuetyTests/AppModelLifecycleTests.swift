import Foundation
import Testing

@testable import Cuety

/// Launch and teardown ownership: the launch sequence runs once, and stops
/// when the operator says stop.
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

    /// Addresses from the documentation range, which cannot be routed.
    ///
    /// A probe against one parks until the request timeout, which is how a
    /// test gets a refresh to stay in flight long enough to do something to it.
    private static let unroutableHost = "192.0.2.1"
    private static let otherUnroutableHost = "192.0.2.2"

    @Test("Starting twice performs the launch sequence once")
    func startIsIdempotent() throws {
        let model = try makeModel()
        defer { model.startupTask?.cancel() }

        model.start()
        let first = try #require(model.startupTask)

        // The second and third calls are what a reopened window does. Under a
        // `WindowGroup` every main window ran this, and each one started an
        // untracked task that restarted discovery and could reconnect the
        // session all of them shared.
        model.start()
        model.start()

        #expect(model.startupTask == first)
    }

    @Test("Disconnecting stops the launch reconnect")
    func disconnectCancelsAutoConnect() throws {
        // Auto-connect polls for ten seconds and stands down once a workspace
        // is selected. `disconnect()` clears the selection, which on its own
        // reads as "nothing chosen yet" — so without cancellation the poll
        // would hand the show back to the workspace just left.
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

        // The three surfaces that offer connection actions — the Connection
        // menu, the sidebar, and the connection inspector — read these and
        // nothing else, so agreeing here is agreeing everywhere.
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

        // Launch used to skip This Mac deliberately, so the most common setup
        // of all — QLab on this machine — required clicking Check for
        // Workspaces before Cuety would look at the Mac it was running on,
        // while every Bonjour server was probed unasked.
        //
        // Whether the probe *succeeds* depends on whether QLab happens to be
        // running here, which is not this test's business. That it was asked
        // at all is.
        #expect(model.browser.server(withID: localhostID)?.hasBeenProbed == true)
    }

    @Test("A server that appears mid-refresh is probed by that refresh")
    func serversFoundMidRefreshAreProbed() async throws {
        let model = try makeModel(requestTimeout: 1)

        // Something slow to probe, so the refresh is still working when the
        // new server turns up. `Task { }` only *schedules* the refresh, so
        // without this the addition below would land before the refresh body
        // ran at all — and the test would pass against the snapshotting
        // version it is meant to catch.
        let blocking = model.browser.addManualServer(host: Self.unroutableHost, port: 53000)

        let refreshing = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(200))
        try #require(model.isRefreshing)

        // Stands in for Bonjour reporting a machine partway through, which is
        // the ordinary case: discovery is asynchronous and `restartBrowsing()`
        // deliberately re-asks the network.
        let late = model.browser.addManualServer(
            host: Self.otherUnroutableHost, port: 53000
        )
        try #require(late.id != blocking.id)

        await refreshing.value

        // Asked at all is the claim. Whether it answered depends on there
        // being a QLab at that address, which is not this test's business —
        // and there is not, by construction.
        #expect(model.browser.server(withID: late.id)?.hasBeenProbed == true)
        #expect(model.browser.server(withID: blocking.id)?.hasBeenProbed == true)
    }

    @Test("Refresh stays available while a refresh is running")
    func refreshIsNotLockedOutByItself() throws {
        let model = try makeModel()

        // One unreachable server costs a full request timeout and they are
        // probed one after another, so a refresh can run for a long time.
        // Refusing for the duration left the operator watching a sidebar they
        // could see was stale and could do nothing about — pressing it again
        // now supersedes the pass in progress.
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

        // Reopening the window after disconnecting must not resurrect the
        // launch reconnect the operator just cancelled.
        model.start()

        #expect(model.startupTask == startup)
        #expect(startup.isCancelled)
    }
}
