import SwiftUI

/// The root of Cuety's observable state.
///
/// Scenes reach this through the environment. It owns the long-lived
/// collaborators — preferences, the activity log, the browser, the QLab client
/// — so that auxiliary windows observe exactly the same state the main window
/// does, and coordinates the flows that span more than one of them.
@Observable
@MainActor
final class AppModel {
    let preferences: Preferences
    let log: ActivityLog
    let client: QLabClient
    let browser: QLabBrowser
    let passcodes = PasscodeStore()

    // MARK: Selection

    /// The workspace the user has chosen in the sidebar.
    var selection: WorkspaceSelection?

    /// True while workspace discovery is refreshing.
    private(set) var isRefreshing = false

    // MARK: Passcode prompting

    /// Set when a workspace needs a passcode we don't have, or rejected the one
    /// we tried. Drives the passcode sheet.
    var passcodePrompt: PasscodePrompt?

    struct PasscodePrompt: Identifiable, Hashable {
        let serverID: String
        let workspaceID: String
        let workspaceName: String
        /// True when a submitted passcode was refused.
        var wasRejected: Bool

        var id: String { "\(serverID)|\(workspaceID)" }
    }

    // MARK: Presentation

    /// Full-screen stage mode: sidebar, header, and drawer hidden, cue number
    /// scaled to fill the window.
    var isPresenting = false

    /// Sidebar visibility in the main window, tracked here so the presentation
    /// mode command can collapse it and restore it afterwards.
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    private var sidebarVisibilityBeforePresenting: NavigationSplitViewVisibility = .automatic

    /// Holds the display awake while enabled.
    private let displaySleepBlocker = DisplaySleepBlocker()

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        let log = ActivityLog()
        self.log = log
        self.client = QLabClient(preferences: preferences, log: log)
        self.browser = QLabBrowser()
        self.client.onPasscodeRequired = { [weak self] rejected in
            guard let self, let selection = self.selection else { return }
            if rejected { self.forgetPasscode(for: selection) }
            self.passcodePrompt = PasscodePrompt(
                serverID: selection.serverID, workspaceID: selection.workspaceID,
                workspaceName: self.workspaceName(for: selection) ?? "this workspace",
                wasRejected: rejected
            )
        }

        // Apply the persisted keep-awake preference at launch, so the setting
        // survives a relaunch rather than silently resetting.
        if preferences.keepsDisplayAwake {
            displaySleepBlocker.setEnabled(true)
        }
    }

    // MARK: - Lifecycle

    func start() {
        browser.start()
        Task {
            await refresh()
            await autoConnectIfNeeded()
        }
    }

    /// Rebuilds everything Cuety knows about QLab, from discovery down to the
    /// live session.
    ///
    /// Three steps, in the only order their dependencies allow:
    ///
    /// 1. Restart Bonjour discovery, so machines that have appeared or gone
    ///    since launch are reflected rather than remembered.
    /// 2. Re-ask every server, discovered or manual, what it has open. Failures
    ///    are recorded per server rather than thrown: one unreachable machine
    ///    must not stop the others from appearing in the sidebar.
    /// 3. Rebuild the live session — socket, handshake, subscriptions, cue
    ///    lists, playheads, and the detail pills — via ``QLabClient/reconnect()``.
    ///
    /// Step 3 is the reason this is more than a data refresh, and the reason the
    /// cue display flickers through `connecting` on the way: the operator
    /// reaching for Refresh is usually doing it *because* something has gone
    /// stale in a way that asking politely won't fix.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        browser.restartBrowsing()

        var updatedServers = browser.servers
        for (index, server) in updatedServers.enumerated() {
            do {
                updatedServers[index].workspaces = try await client.fetchWorkspaces(from: server)
                updatedServers[index].lastError = nil
            } catch {
                updatedServers[index].workspaces = []
                updatedServers[index].lastError = String(describing: error)
            }
        }
        browser.update(updatedServers)

        if client.status.hasLiveData {
            await client.reconnect()
        }
    }

    // MARK: - Auto-connect

    /// How long after launch Cuety keeps looking for the last-used workspace.
    private static let autoConnectWindow: Duration = .seconds(10)

    /// How long to wait between re-asking the servers during that window.
    private static let autoConnectPollInterval: Duration = .seconds(2)

    /// Reconnects to the last-used workspace, giving Bonjour time to find it.
    ///
    /// A single attempt at launch would nearly always miss: discovery is
    /// asynchronous, so the workspace usually isn't in the browser's list yet
    /// when the app finishes starting. Instead this re-asks over a bounded
    /// window and gives up quietly when it closes.
    ///
    /// Every path out checks `selection` first. An automatic connection must
    /// never overrule the operator — if they pick a workspace themselves while
    /// this is still polling, that choice stands and this stops.
    private func autoConnectIfNeeded() async {
        guard preferences.autoConnect, let target = preferences.lastWorkspace else { return }

        let deadline = ContinuousClock.now + Self.autoConnectWindow
        while ContinuousClock.now < deadline {
            guard selection == nil else { return }

            if isKnown(target) {
                await connect(to: target, useSavedPasscode: true)
                return
            }

            try? await Task.sleep(for: Self.autoConnectPollInterval)
            guard selection == nil else { return }
            await refresh()
        }
    }

    /// Whether a workspace is currently open on a server we can see, and so
    /// worth attempting a connection to.
    private func isKnown(_ selection: WorkspaceSelection) -> Bool {
        browser.server(withID: selection.serverID)?
            .workspaces.contains { $0.uniqueID == selection.workspaceID }
            ?? false
    }

    // MARK: - Connecting

    /// Workspace selection tries without credentials first. Launch restoration
    /// can reuse a passcode the operator previously chose to remember.
    func connect(to selection: WorkspaceSelection, useSavedPasscode: Bool = false) async {
        guard let server = browser.server(withID: selection.serverID) else { return }

        self.selection = selection
        passcodePrompt = nil
        let stored = useSavedPasscode ? passcodes.passcode(
            serverID: selection.serverID, workspaceID: selection.workspaceID
        ) : nil

        await client.connect(
            to: server,
            workspaceID: selection.workspaceID,
            passcode: stored
        )

        // Only a connection that actually reached the workspace is worth
        // restoring at launch, so a failed or refused attempt doesn't become
        // the thing Cuety tries again tomorrow.
        if client.status.hasLiveData {
            preferences.lastWorkspace = selection
        }
    }

    /// One explicit attempt. Keep the sheet open on failure and save only a
    /// credential that reached a live workspace session.
    func submitPasscode(
        _ passcode: String, for prompt: PasscodePrompt, remember: Bool
    ) async {
        guard let server = browser.server(withID: prompt.serverID) else { return }
        let target = WorkspaceSelection(
            serverID: prompt.serverID, workspaceID: prompt.workspaceID
        )
        selection = target
        await client.connect(to: server, workspaceID: prompt.workspaceID, passcode: passcode)

        if client.status.hasLiveData {
            if remember {
                try? passcodes.save(
                    passcode, serverID: prompt.serverID, workspaceID: prompt.workspaceID
                )
                preferences.lastWorkspace = target
            }
            passcodePrompt = nil
        }
    }

    func disconnect() {
        passcodePrompt = nil
        client.disconnect()
        selection = nil
    }

    /// Drops a stored passcode, for the Settings "forget" affordance.
    func forgetPasscode(for selection: WorkspaceSelection) {
        try? passcodes.remove(
            serverID: selection.serverID, workspaceID: selection.workspaceID
        )
    }

    /// Drops every stored passcode.
    ///
    /// The blunt instrument Settings needs: Cuety can only list passcodes for
    /// workspaces it can currently see, so this is the only way to clear ones
    /// belonging to a machine that has since gone away.
    func forgetAllPasscodes() {
        try? passcodes.removeAll()
    }

    private func workspaceName(for selection: WorkspaceSelection) -> String? {
        browser.server(withID: selection.serverID)?
            .workspaces.first { $0.uniqueID == selection.workspaceID }?
            .displayName
    }

    // MARK: - Chrome

    /// Enters or leaves presentation mode, animating the whole layout change
    /// as one transition.
    func togglePresentationMode() {
        withAnimation(Motion.chrome) {
            if isPresenting {
                isPresenting = false
                sidebarVisibility = sidebarVisibilityBeforePresenting
            } else {
                sidebarVisibilityBeforePresenting = sidebarVisibility
                isPresenting = true
                sidebarVisibility = .detailOnly
            }
        }
    }

    func toggleDrawer() {
        withAnimation(Motion.chrome) {
            preferences.showsDrawer.toggle()
        }
    }

    func toggleKeepAwake() {
        preferences.keepsDisplayAwake.toggle()
        displaySleepBlocker.setEnabled(preferences.keepsDisplayAwake)
    }
}
