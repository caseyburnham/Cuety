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

    // MARK: Passcode prompting

    /// Set when a workspace needs a passcode we don't have, or rejected the one
    /// we tried. Drives the passcode sheet.
    var passcodePrompt: PasscodePrompt?

    struct PasscodePrompt: Identifiable, Hashable {
        let serverID: String
        let workspaceID: String
        let workspaceName: String
        /// True when a passcode was tried and refused, so the sheet can warn
        /// about QLab's escalating delay.
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
            await refreshWorkspaces()
            await autoConnectIfNeeded()
        }
    }

    /// Asks every known server what workspaces it has open.
    ///
    /// Failures are recorded per server rather than thrown: one unreachable
    /// machine must not stop the others from appearing in the sidebar.
    func refreshWorkspaces() async {
        for server in browser.servers {
            do {
                let workspaces = try await client.fetchWorkspaces(from: server)
                var updated = server
                updated.workspaces = workspaces
                updated.lastError = nil
                browser.update(updated)
            } catch {
                var updated = server
                updated.workspaces = []
                updated.lastError = String(describing: error)
                browser.update(updated)
            }
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
                await connect(to: target)
                return
            }

            try? await Task.sleep(for: Self.autoConnectPollInterval)
            guard selection == nil else { return }
            await refreshWorkspaces()
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

    /// Connects to a workspace, using a stored passcode if one exists and
    /// prompting if QLab refuses.
    func connect(to selection: WorkspaceSelection) async {
        guard let server = browser.server(withID: selection.serverID) else { return }

        self.selection = selection
        let stored = passcodes.passcode(
            serverID: selection.serverID, workspaceID: selection.workspaceID
        )

        await client.connect(
            to: server,
            workspaceID: selection.workspaceID,
            passcode: stored
        )

        // The client sets `needsPasscode` when QLab wants credentials we don't
        // have or refused the ones we sent.
        if case .needsPasscode(let rejected) = client.status {
            passcodePrompt = PasscodePrompt(
                serverID: selection.serverID,
                workspaceID: selection.workspaceID,
                workspaceName: workspaceName(for: selection) ?? "this workspace",
                wasRejected: rejected
            )
        }

        // Only a connection that actually reached the workspace is worth
        // restoring at launch, so a failed or refused attempt doesn't become
        // the thing Cuety tries again tomorrow.
        if client.status.hasLiveData {
            preferences.lastWorkspace = selection
        }
    }

    /// Saves a passcode and retries the connection once.
    ///
    /// Deliberately a single explicit retry driven by the user pressing Connect
    /// — QLab lengthens its own delay after repeated failures, so an automatic
    /// retry loop would make a mistyped passcode progressively worse.
    func submitPasscode(_ passcode: String, for prompt: PasscodePrompt) async {
        try? passcodes.save(
            passcode, serverID: prompt.serverID, workspaceID: prompt.workspaceID
        )
        passcodePrompt = nil

        await connect(
            to: WorkspaceSelection(
                serverID: prompt.serverID, workspaceID: prompt.workspaceID
            )
        )
    }

    /// Connects with a passcode without saving it, for a one-off session on
    /// someone else's machine.
    ///
    /// Deliberately does not record the workspace for auto-connect: with no
    /// passcode in the Keychain, restoring it at launch could only produce a
    /// passcode prompt, which is not what "one-off" should mean.
    func connectOnce(withPasscode passcode: String, for prompt: PasscodePrompt) async {
        guard let server = browser.server(withID: prompt.serverID) else { return }

        selection = WorkspaceSelection(
            serverID: prompt.serverID, workspaceID: prompt.workspaceID
        )
        await client.connect(
            to: server, workspaceID: prompt.workspaceID, passcode: passcode
        )

        if case .needsPasscode(let rejected) = client.status {
            passcodePrompt = PasscodePrompt(
                serverID: prompt.serverID,
                workspaceID: prompt.workspaceID,
                workspaceName: prompt.workspaceName,
                wasRejected: rejected
            )
        }
    }

    func disconnect() {
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

    var isKeepingDisplayAwake: Bool { displaySleepBlocker.isEnabled }
}
