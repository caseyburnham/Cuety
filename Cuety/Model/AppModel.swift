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
        Task { await refreshWorkspaces() }
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
