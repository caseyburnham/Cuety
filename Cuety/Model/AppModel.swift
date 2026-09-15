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
    let passcodes: any PasscodeStoring

    // MARK: Selection

    /// The workspace the user has chosen in the sidebar.
    var selection: WorkspaceSelection?

    /// True while workspace discovery is refreshing.
    private(set) var isRefreshing = false

    /// The servers a probe is contacting *right now*.
    ///
    /// Not every refresh asks every server, so the sidebar needs this to avoid
    /// claiming it is looking for workspaces on a machine it has decided to
    /// leave alone. Probes run one at a time, so in practice this holds one ID
    /// during a global refresh and the spinner walks down the list — which is
    /// the truthful rendering. Marking every queued server as "refreshing" up
    /// front made the same claim about machines that had not been asked yet.
    private(set) var refreshingServerIDs: Set<String> = []

    // MARK: Stored credentials

    /// The workspaces Cuety holds a passcode for, as far as it can tell.
    ///
    /// Observable, and the only thing Settings reads. The Keychain has no
    /// change notification, so a view that asked it directly had nothing to
    /// invalidate it: Forget removed the credential and left the row on
    /// screen until something unrelated redrew the window.
    ///
    /// Limited to workspaces Cuety can currently see, because `SecItem` offers
    /// no listing that would give names to show. An item belonging to a
    /// machine that has gone away can still only be cleared with Forget All —
    /// which is why that button exists.
    private(set) var storedPasscodeSelections: Set<WorkspaceSelection> = []

    /// A credential-store failure worth telling the operator about.
    ///
    /// Keychain writes used to be `try?`, so a passcode that failed to save
    /// looked saved, and a Forget that failed looked forgotten.
    var credentialError: CredentialError?

    struct CredentialError: Identifiable, Hashable {
        let id = UUID()
        /// What Cuety was attempting, in the operator's terms.
        let action: String
        let reason: String

        var message: String { "\(action) \(reason)" }
    }

    /// Whether the Add Server sheet is up.
    ///
    /// Owned here rather than by the sidebar because two things open it — the
    /// sidebar's button and ⌘K from the Connection menu — and a menu command
    /// cannot reach a view's local state.
    var isAddingServer = false

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
    //
    // Both of these describe *the* main window, and there is now exactly one
    // of those — a single `Window` scene. They always lived here, which under
    // a `WindowGroup` meant two main windows shared one presentation state and
    // one sidebar visibility: entering presentation mode in either collapsed
    // the sidebar in both. That is fixed by there being one window, not by
    // moving state, because per-window state is not what this app wants.

    /// Stage mode: the window in real full screen, sidebar, toolbar and drawer
    /// hidden, cue number scaled to fill the display.
    ///
    /// Both an intent and a mirror. Setting it asks
    /// ``FullScreenPresentation`` to take the window into or out of full
    /// screen; the window entering or leaving full screen by any other route
    /// sets it back. So this is never a claim about full screen that the window
    /// disagrees with — which it would be if it were only an intent, since full
    /// screen has entrances Cuety does not own.
    var isPresenting = false

    /// Whether the main window's sidebar is showing, tracked here so the
    /// presentation mode command can collapse it and restore it afterwards.
    ///
    /// A `Bool`, because a sidebar either is or is not collapsed. This was a
    /// `NavigationSplitViewVisibility` while the window was a
    /// `NavigationSplitView`, and the third state was never Cuety's to want:
    /// `.automatic` meant "whatever SwiftUI decides", which is not a thing
    /// presentation mode can save and put back.
    var isSidebarVisible = true

    private var wasSidebarVisibleBeforePresenting = true

    /// Holds the display awake while enabled.
    private let displaySleepBlocker = DisplaySleepBlocker()

    /// Keeps the Dock tile's badge on the cue standing by.
    private let dockBadge = DockBadge()

    init(
        preferences: Preferences = Preferences(),
        passcodes: any PasscodeStoring = PasscodeStore()
    ) {
        self.preferences = preferences
        self.passcodes = passcodes
        let log = ActivityLog()
        self.log = log
        self.client = QLabClient(preferences: preferences, log: log)
        // The same store the preferences use, not `.standard`. The browser
        // persists the manual server list, so reaching for the shared domain
        // here made test isolation a fiction — an isolated `Preferences` still
        // left tests adding servers to whatever the real app would read back.
        self.browser = QLabBrowser(defaults: preferences.defaults)
        self.client.onPasscodeRequired = { [weak self] rejected in
            guard let self, let selection = self.selection else { return }
            if rejected { self.forgetPasscode(for: selection) }
            self.passcodePrompt = PasscodePrompt(
                serverID: selection.serverID, workspaceID: selection.workspaceID,
                workspaceName: self.workspaceName(for: selection) ?? "this workspace",
                wasRejected: rejected
            )
        }

        self.client.onSessionEnded = { [weak self] end in
            guard let self else { return }
            switch end {
            case .workspaceClosed:
                // The workspace is gone, so the sidebar is now offering a row
                // that would fail if it were clicked, and the selection points
                // at something that no longer exists. Clear the selection and
                // re-ask that one server what it actually has open — the rest
                // of the network is not in question, and a full refresh would
                // needlessly rebuild connections that are perfectly fine.
                let serverID = self.selection?.serverID
                self.selection = nil
                guard let serverID else { return }
                Task { await self.refreshWorkspaces(onServerWithID: serverID) }
            }
        }

        // Apply the persisted keep-awake preference at launch, so the setting
        // survives a relaunch rather than silently resetting.
        if preferences.keepsDisplayAwake {
            displaySleepBlocker.setEnabled(true)
        }
    }

    // MARK: - Lifecycle

    /// The launch sequence: discovery, one probe of the network, and the
    /// automatic reconnect to the last-used workspace.
    ///
    /// Held rather than fired and forgotten, for two reasons. It has to be
    /// stoppable — see ``disconnect()`` — and holding it is what makes
    /// ``start()`` idempotent.
    ///
    /// Never cleared on completion: the guard below asks "has this launched?",
    /// not "is it running?". Clearing it would let a second call re-run
    /// discovery and auto-connect after the first had finished, which is the
    /// same fault by a slower route.
    ///
    /// Readable rather than fully private so the two properties that make it
    /// safe can be asserted: that it is created once, and that it is cancelled
    /// when the operator disconnects.
    private(set) var startupTask: Task<Void, Never>?

    /// Starts discovery and the launch reconnect. Safe to call more than once;
    /// only the first call does anything.
    ///
    /// The main window is a single `Window` now, so in practice this runs once
    /// — but the guarantee must not rest on the scene type. Closing the window
    /// and reopening it from the Window menu runs the view's `task` again, and
    /// a future scene change should not be able to quietly restore the old
    /// behaviour where every window started its own untracked launch sequence.
    func start() {
        guard startupTask == nil else { return }

        // Started here rather than in `init` so that a preview or a test
        // building an ``AppModel`` does not reach for the running app's Dock
        // tile. Idempotent in its own right, so the guard above is not what
        // makes this safe.
        dockBadge.follow { [weak self] in self?.dockBadgeLabel ?? nil }

        browser.start()
        startupTask = Task { [weak self] in
            guard let self else { return }
            // Every server, This Mac included. Launch used to skip it, on the
            // grounds that probing 127.0.0.1 unasked "just refuses a
            // connection every launch" — but QLab on this Mac is the single
            // most common setup, so the usual outcome was the operator having
            // to click Check for Workspaces before Cuety would look at the
            // machine it is running on. Meanwhile every Bonjour server was
            // probed automatically, which made the exclusion inconsistent as
            // well as unhelpful. A refused connection on loopback is
            // immediate and the sidebar has honest wording for it.
            await self.refresh()
            await self.autoConnectIfNeeded()
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
    ///
    /// Asking again **supersedes** the refresh in progress rather than being
    /// refused. A refresh can take a while — one unreachable server costs a
    /// full request timeout, and they are probed one after another — and
    /// refusing for the duration meant a stale sidebar the operator could see
    /// was stale and could not do anything about. Pressing it again is the
    /// clearest possible statement of intent, so it starts over.
    func refresh() async {
        // Cancel first: the in-flight pass stops at its next server, and its
        // cancelled probe publishes nothing.
        refreshTask?.cancel()

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshTask = task
        await task.value
    }

    /// How many times a refresh re-checks for servers that appeared while it
    /// was running.
    ///
    /// Bounded, and low. Each pass costs a round trip per newly found server,
    /// and the point is only to catch machines Bonjour reported *during* the
    /// first pass — not to sit and wait for the network to settle, which would
    /// hold the refresh indicator on and is what a second press of Refresh is
    /// for. Servers appearing after the last pass are left showing "Check for
    /// Workspaces", which is honest.
    private static let refreshDiscoveryPasses = 3

    private var refreshTask: Task<Void, Never>?

    /// Which refresh owns `isRefreshing`, so a superseded pass finishing late
    /// cannot switch the indicator off under the one that replaced it.
    private var refreshGeneration = 0

    private func performRefresh(generation: Int) async {
        defer {
            if generation == refreshGeneration { isRefreshing = false }
        }

        browser.restartBrowsing()

        // Probed in passes rather than from one snapshot, because the list
        // grows while this runs: `restartBrowsing()` above deliberately
        // re-asks the network and Bonjour answers asynchronously, so a machine
        // can appear halfway through. Taking the list once left those servers
        // showing "Check for Workspaces" *immediately after a refresh*, which
        // reads as the refresh having skipped them.
        //
        // Each pass only probes what the previous ones did not, so a server
        // present from the start is still asked exactly once.
        var probed: Set<String> = []

        for _ in 0..<Self.refreshDiscoveryPasses {
            let pending = browser.servers.filter { !probed.contains($0.id) }
            guard !pending.isEmpty else { break }

            for target in pending {
                // Checked before each request, not just at the top. A cancelled
                // launch sequence — the operator disconnecting inside the
                // auto-connect window — must stop asking, not work through the
                // rest of the network first.
                guard !Task.isCancelled else { return }
                probed.insert(target.id)
                await probeWorkspaces(on: target)
            }
        }

        guard !Task.isCancelled else { return }

        // Any session Cuety is holding open, not just a live one. An operator
        // reaching for Refresh while a reconnect is backing off wants it tried
        // now — waiting out a thirty-second timer is the opposite of what they
        // just asked for.
        if client.isSessionActive {
            await client.reconnect()
        }
    }

    /// Re-asks one server what it has open, leaving the other servers and the
    /// live session alone — which ``refresh()`` would not.
    func refreshWorkspaces(onServerWithID id: String) async {
        guard let server = browser.server(withID: id) else { return }
        await probeWorkspaces(on: server)
    }

    /// Which probe currently owns each server's result.
    ///
    /// Ownership is per *server*, which is the level the conflict actually
    /// happens at. A global refresh used to snapshot the whole server list,
    /// probe some of it, and publish the entire snapshot at the end — so a
    /// single-server refresh that landed in between was overwritten by values
    /// the global refresh had never even re-asked for. Superseding the whole
    /// global refresh instead would be the opposite mistake: re-asking one
    /// machine is no reason to abandon the other five.
    private var probeGenerationByServerID: [String: Int] = [:]
    private var lastProbeGeneration = 0

    /// Asks one server what it has open and publishes the answer, unless a
    /// newer probe of the same server has taken over.
    ///
    /// The single place server-probe bookkeeping lives: the fetch, the error
    /// capture, the `hasBeenProbed` flag, and the in-flight indicator. It was
    /// written out twice before, once per caller, and the two copies had
    /// already drifted.
    private func probeWorkspaces(on target: QLabServer) async {
        lastProbeGeneration += 1
        let generation = lastProbeGeneration
        probeGenerationByServerID[target.id] = generation

        refreshingServerIDs.insert(target.id)

        var server = target
        do {
            server.workspaces = try await client.fetchWorkspaces(from: target)
            server.lastError = nil
        } catch is CancellationError {
            // Cuety stopped asking. That is not a fault of the server's, and
            // recording it as one would put "the operation was cancelled"
            // under a machine that was answering perfectly well. Clear the
            // indicator here rather than relying on a caller's cleanup, or an
            // abandoned probe leaves a spinner running for good.
            relinquishProbe(of: target.id, generation: generation)
            return
        } catch {
            server.workspaces = []
            server.lastError = String(describing: error)
        }
        server.hasBeenProbed = true

        // Superseded while the request was in flight. The newer probe's answer
        // is the current one, and it owns the indicator too — so this one
        // publishes nothing and touches nothing.
        guard probeGenerationByServerID[target.id] == generation else { return }
        relinquishProbe(of: target.id, generation: generation)
        browser.update(server)

        // Workspaces just became visible that may have credentials stored in
        // an earlier session, and Settings can only list what Cuety can see.
        refreshStoredPasscodes()
    }

    /// Hands back ownership of a server's probe, if this probe still holds it.
    private func relinquishProbe(of serverID: String, generation: Int) {
        guard probeGenerationByServerID[serverID] == generation else { return }
        probeGenerationByServerID.removeValue(forKey: serverID)
        refreshingServerIDs.remove(serverID)
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
    /// Every path out checks cancellation and `selection` first. An automatic
    /// connection must never overrule the operator — if they pick a workspace
    /// themselves while this is still polling, that choice stands and this
    /// stops. And if they *disconnect* while it is polling, cancellation is
    /// what stops it: clearing the selection would otherwise read as "nothing
    /// chosen yet" and hand the show straight back to the workspace they just
    /// left.
    private func autoConnectIfNeeded() async {
        guard preferences.autoConnect, let target = preferences.lastWorkspace else { return }

        let deadline = ContinuousClock.now + Self.autoConnectWindow
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, selection == nil else { return }

            if isKnown(target) {
                await connect(to: target, useSavedPasscode: true)
                return
            }

            try? await Task.sleep(for: Self.autoConnectPollInterval)
            guard !Task.isCancelled, selection == nil else { return }
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

    // MARK: - Connection action availability
    //
    // One definition per action, stated in terms of what the operator is
    // trying to do rather than what data happens to be on screen. Three
    // surfaces offer these actions — the Connection menu, the sidebar, and the
    // connection inspector — and they disagreed about all of them.
    //
    // The rule for every one: `hasLiveData` answers "is there anything to
    // show", which is not the same question as "is there a session here". A
    // reconnect backoff has nothing to show and is emphatically a session.

    /// Whether Disconnect should be offered.
    ///
    /// Any session Cuety is holding open — live, mid-connect, or waiting out a
    /// reconnect backoff. The menu tested `hasLiveData`, which greyed
    /// Disconnect out for the whole thirty-second backoff: precisely the
    /// stretch in which an operator wants to call it off, and during which the
    /// alternative on offer was a Connect button for the workspace Cuety was
    /// already trying to reach.
    var canDisconnect: Bool { client.isSessionActive }

    /// Whether starting a *new* connection should be offered.
    ///
    /// Blocked only while an attempt is genuinely in flight. `reconnecting` is
    /// deliberately not blocked: its backoff can run for half a minute, and an
    /// operator who has decided to go somewhere else should not have to wait
    /// it out — see ``ConnectionStatus/isTransitional``.
    var canConnect: Bool { !client.status.isTransitional }

    /// Whether Refresh should be offered.
    ///
    /// Deliberately *not* blocked by a refresh already running — pressing it
    /// again supersedes that one, so the operator is never stuck watching a
    /// sidebar they know is stale. It is blocked during connection setup,
    /// because Refresh rebuilds the live session and would tear down the very
    /// attempt it was racing. The menu allowed exactly that, while the
    /// sidebar's button did not.
    var canRefresh: Bool { !client.status.isTransitional }

    /// Whether a server entry is the operator's to remove.
    ///
    /// A Bonjour server is not: it is in the list because the machine is on
    /// the network, so "removing" it would only hide something Cuety would
    /// rediscover seconds later. The built-in "This Mac" entry is not either —
    /// it costs nothing and is the most common case.
    func canRemove(_ server: QLabServer) -> Bool {
        server.source == .manual && server.id != QLabServer.localhost().id
    }

    /// Forgets a manually added server, ending the session first when it is
    /// the server that session is on.
    ///
    /// Here rather than at each call site because there are now two of them —
    /// the sidebar's context menus and the Connection settings pane — and
    /// "removing the server you are connected to has to disconnect first" is
    /// one rule, not two. Deliberately not gated on ``canConnect``: that
    /// blocked removing an unrelated machine for the whole of someone else's
    /// connection attempt, and ``disconnect()`` is available mid-connect
    /// precisely so an attempt can be called off.
    func removeServer(withID id: String) {
        if selection?.serverID == id { disconnect() }
        browser.removeManualServer(id: id)
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

        guard client.status.hasLiveData else { return }

        // Remembering the *workspace* is not conditional on remembering the
        // *passcode*. Those are two unrelated preferences, and coupling them
        // meant declining to store a credential also quietly opted out of
        // reconnecting at launch — a setting the operator had turned on
        // somewhere else entirely.
        preferences.lastWorkspace = target

        if remember {
            do {
                try passcodes.save(
                    passcode, serverID: prompt.serverID, workspaceID: prompt.workspaceID
                )
                storedPasscodeSelections.insert(target)
            } catch {
                // The connection succeeded; only the saving failed. Say so,
                // rather than leaving the operator believing a passcode is
                // stored that will not be there next time.
                credentialError = CredentialError(
                    action: "Cuety connected, but could not save the passcode to your Keychain.",
                    reason: describe(error)
                )
            }
        }

        passcodePrompt = nil
    }

    /// Turns a credential-store error into something an operator can read.
    private func describe(_ error: any Error) -> String {
        (error as? any OperatorReadableError)?.description ?? error.localizedDescription
    }

    func disconnect() {
        // Stop the launch reconnect first, and before `selection` is cleared.
        //
        // ``autoConnectIfNeeded()`` polls for up to ten seconds and stands
        // down as soon as the operator has chosen a workspace — but clearing
        // the selection is exactly what re-arms it. Disconnecting inside that
        // window therefore used to be undone a second or two later by Cuety
        // reconnecting to the workspace the operator had just left.
        startupTask?.cancel()

        passcodePrompt = nil
        client.disconnect()
        selection = nil
    }

    /// Drops a stored passcode, for the Settings "forget" affordance.
    func forgetPasscode(for selection: WorkspaceSelection) {
        do {
            try passcodes.remove(
                serverID: selection.serverID, workspaceID: selection.workspaceID
            )
            // Updated here so Settings redraws. Reading the Keychain from a
            // view gave Forget nothing to invalidate, so the row stayed.
            storedPasscodeSelections.remove(selection)
        } catch {
            credentialError = CredentialError(
                action: "Cuety could not remove that passcode from your Keychain.",
                reason: describe(error)
            )
        }
    }

    /// Drops every stored passcode.
    ///
    /// The blunt instrument Settings needs: Cuety can only list passcodes for
    /// workspaces it can currently see, so this is the only way to clear ones
    /// belonging to a machine that has since gone away.
    func forgetAllPasscodes() {
        do {
            try passcodes.removeAll()
            storedPasscodeSelections.removeAll()
        } catch {
            credentialError = CredentialError(
                action: "Cuety could not clear the saved passcodes from your Keychain.",
                reason: describe(error)
            )
        }
    }

    /// Rebuilds ``storedPasscodeSelections`` from the workspaces currently
    /// visible.
    ///
    /// Needed because the set can only ever describe what Cuety can see, and
    /// what it can see changes: a server appearing brings workspaces whose
    /// credentials were stored in an earlier session. Called when a probe
    /// publishes and when Settings appears.
    func refreshStoredPasscodes() {
        var found: Set<WorkspaceSelection> = []
        for server in browser.servers {
            for workspace in server.workspaces {
                let selection = WorkspaceSelection(
                    serverID: server.id, workspaceID: workspace.uniqueID
                )
                if passcodes.hasPasscode(
                    serverID: selection.serverID, workspaceID: selection.workspaceID
                ) {
                    found.insert(selection)
                }
            }
        }
        storedPasscodeSelections = found
    }

    private func workspaceName(for selection: WorkspaceSelection) -> String? {
        browser.server(withID: selection.serverID)?
            .workspaces.first { $0.uniqueID == selection.workspaceID }?
            .displayName
    }

    // MARK: - Readouts outside the window

    /// The cue standing by, and only while the session is live enough for it
    /// to still be standing by.
    ///
    /// The same contract ``CueDisplayView/liveCue`` states for the headline,
    /// for the surfaces that are not the headline: the menu bar item and the
    /// Dock badge. A stale cue number on a stage display is the worst thing
    /// this app can do, and one sitting on the Dock after the session dropped
    /// is the same lie told somewhere the operator is even less likely to
    /// question it.
    var standbyCue: Cue? {
        guard client.status.hasLiveData else { return nil }
        return client.playheadCue
    }

    /// What the Dock tile should be badged with, or `nil` for no badge.
    ///
    /// The cue number and nothing else. ``MenuBarReadout`` offers the
    /// connection status and the heartbeat as well, because a menu bar item
    /// can draw a glyph; a Dock badge is a short string, and "Degraded"
    /// spelled out in a red pill would be neither readable nor useful.
    var dockBadgeLabel: String? {
        guard preferences.showsDockBadge else { return nil }
        return standbyCue?.displayNumber
    }

    // MARK: - Chrome

    /// Enters or leaves presentation mode.
    func togglePresentationMode() {
        setPresenting(!isPresenting)
    }

    /// Sets presentation mode, animating the whole layout change as one
    /// transition.
    ///
    /// More than a setter: entering has to remember the sidebar so that leaving
    /// can put it back. Two things call this — the View menu, and
    /// ``FullScreenPresentation`` when the window enters or leaves full screen
    /// by some other route (the green button, the system's own ⌃⌘F, Mission
    /// Control).
    ///
    /// Which is why the guard is load-bearing rather than a micro-optimisation.
    /// The window reporting a state Cuety is already in must not re-save the
    /// sidebar, or entering presentation mode would store `.detailOnly` over
    /// the visibility that was meant to be restored afterwards — and the
    /// sidebar would never come back.
    func setPresenting(_ presenting: Bool) {
        guard presenting != isPresenting else { return }
        withAnimation(Motion.chrome.unlessMotionIsReduced) {
            if presenting {
                wasSidebarVisibleBeforePresenting = isSidebarVisible
                isPresenting = true
                isSidebarVisible = false
            } else {
                isPresenting = false
                isSidebarVisible = wasSidebarVisibleBeforePresenting
            }
        }
    }

    /// Collapses or reveals the sidebar.
    ///
    /// Unanimated here: ``MainSplitViewController`` animates the collapse
    /// itself, the way AppKit does it, so wrapping this in `withAnimation`
    /// would only add a second opinion about the timing.
    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleDrawer() {
        withAnimation(Motion.chrome.unlessMotionIsReduced) {
            preferences.showsDrawer.toggle()
        }
    }

    func toggleKeepAwake() {
        preferences.keepsDisplayAwake.toggle()
        displaySleepBlocker.setEnabled(preferences.keepsDisplayAwake)
    }
}
