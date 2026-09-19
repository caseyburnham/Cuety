import SwiftUI

@Observable
@MainActor
final class AppModel {
    let preferences: Preferences
    let log: ActivityLog
    let client: QLabClient
    let browser: QLabBrowser
    let passcodes: any PasscodeStoring

    var selection: WorkspaceSelection?

    private(set) var isRefreshing = false

    private(set) var refreshingServerIDs: Set<String> = []

    private(set) var storedPasscodeSelections: Set<WorkspaceSelection> = []

    var credentialError: CredentialError?

    struct CredentialError: Identifiable, Hashable {
        let id = UUID()
        let action: String
        let reason: String

        var message: String { "\(action) \(reason)" }
    }

    var isAddingServer = false

    var passcodePrompt: PasscodePrompt?

    struct PasscodePrompt: Identifiable, Hashable {
        let serverID: String
        let workspaceID: String
        let workspaceName: String
        var wasRejected: Bool

        var id: String { "\(serverID)|\(workspaceID)" }
    }

#if os(macOS)
    var isPresenting = false
#else
    /// Presentation mode is a macOS window feature. Keeping this unavailable on
    /// iPad prevents the iPad UI from ever presenting a misleading entry point.
    var isPresenting: Bool { false }
#endif

    private(set) var isDataStale = false

    var isSidebarVisible = true

    private var wasSidebarVisibleBeforePresenting = true

    private let displaySleepBlocker = DisplaySleepBlocker()

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
        self.browser = QLabBrowser(defaults: preferences.defaults)
        self.browser.onServerDiscovered = { [weak self] server in
            guard let self else { return }
            Task { await self.handleDiscoveredServer(server) }
        }
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
                let closedSelection = self.selection
                self.selection = nil
                if let closedSelection,
                   self.preferences.lastWorkspace == closedSelection {
                    self.preferences.lastWorkspace = nil
                }
                guard let serverID = closedSelection?.serverID else { return }
                Task { await self.refreshWorkspaces(onServerWithID: serverID) }
            }
        }

        if preferences.keepsDisplayAwake {
            displaySleepBlocker.setEnabled(true)
        }
    }

    private(set) var startupTask: Task<Void, Never>?

    func start() {
        guard startupTask == nil else { return }

        dockBadge.follow { [weak self] in self?.dockBadgeLabel ?? nil }

        autoConnectIsArmed = preferences.autoConnect && preferences.lastWorkspace != nil
        browser.start()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.autoConnectIfPossible()
        }
    }

    /// iPad remains connected while inactive or backgrounded. The operating system
    /// may suspend the process, so retained cue data is explicitly marked stale
    /// until the next foreground refresh confirms it again.
    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard isDataStale else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.refresh()
                // The stale label stays visible while refresh is in flight. A
                // failed refresh replaces it with the client’s explicit error
                // state instead of briefly presenting retained data as current.
                self.isDataStale = false
            }
        case .inactive, .background:
            if client.status.hasLiveData || selection != nil {
                isDataStale = true
            }
        @unknown default:
            break
        }
    }

    func refresh() async {
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

    private static let refreshDiscoveryPasses = 3
    private static let maxConcurrentProbes = 3

    private var refreshTask: Task<Void, Never>?

    private var refreshGeneration = 0

    private func performRefresh(generation: Int) async {
        defer {
            if generation == refreshGeneration { isRefreshing = false }
        }

        browser.restartBrowsing()

        var probed: Set<String> = []

        for _ in 0..<Self.refreshDiscoveryPasses {
            let pending = browser.servers.filter { !probed.contains($0.id) }
            guard !pending.isEmpty else { break }
            probed.formUnion(pending.map(\.id))

            await withTaskGroup(of: Void.self) { group in
                var nextIndex = 0
                for _ in 0..<min(Self.maxConcurrentProbes, pending.count) {
                    let target = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { await self.probeWorkspaces(on: target) }
                }

                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard nextIndex < pending.count else { continue }
                    let target = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { await self.probeWorkspaces(on: target) }
                }
            }

            guard !Task.isCancelled else { return }
        }

        guard !Task.isCancelled else { return }
        await refreshStoredPasscodes()

        if client.isSessionActive {
            await client.reconnect()
        }
    }

    func refreshWorkspaces(onServerWithID id: String) async {
        guard let server = browser.server(withID: id) else { return }
        await probeWorkspaces(on: server)
        await refreshStoredPasscodes()
    }

    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var probeGenerationByServerID: [String: Int] = [:]
    private var lastProbeGeneration = 0

    private func probeWorkspaces(on target: QLabServer) async {
        if let existing = probeTasks[target.id] {
            await existing.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performProbe(target)
        }
        probeTasks[target.id] = task
        await task.value
        probeTasks.removeValue(forKey: target.id)
    }

    private func performProbe(_ target: QLabServer) async {
        lastProbeGeneration += 1
        let generation = lastProbeGeneration
        probeGenerationByServerID[target.id] = generation

        refreshingServerIDs.insert(target.id)

        var server = target
        do {
            server.workspaces = try await client.fetchWorkspaces(from: target)
            server.lastError = nil
        } catch is CancellationError {
            relinquishProbe(of: target.id, generation: generation)
            return
        } catch {
            server.workspaces = []
            server.lastError = error.operatorDescription
        }
        server.hasBeenProbed = true

        guard probeGenerationByServerID[target.id] == generation else { return }
        relinquishProbe(of: target.id, generation: generation)
        browser.update(server)
    }

    private func relinquishProbe(of serverID: String, generation: Int) {
        guard probeGenerationByServerID[serverID] == generation else { return }
        probeGenerationByServerID.removeValue(forKey: serverID)
        refreshingServerIDs.remove(serverID)
    }

    private var autoConnectIsArmed = false

    private func handleDiscoveredServer(_ server: QLabServer) async {
        await probeWorkspaces(on: server)
        await autoConnectIfPossible()
    }

    private func autoConnectIfPossible() async {
        guard autoConnectIsArmed, !Task.isCancelled, selection == nil,
              let target = preferences.lastWorkspace, isKnown(target) else { return }

        autoConnectIsArmed = false
        await connect(to: target, useSavedPasscode: true)
    }

    private func isKnown(_ selection: WorkspaceSelection) -> Bool {
        browser.server(withID: selection.serverID)?
            .workspaces.contains { $0.uniqueID == selection.workspaceID }
            ?? false
    }

    var canDisconnect: Bool { client.isSessionActive }

    var canConnect: Bool { !client.status.isTransitional }

    var canRefresh: Bool { !client.status.isTransitional }

    func canRemove(_ server: QLabServer) -> Bool {
        server.source == .manual && server.id != QLabServer.localhost().id
    }

    func removeServer(withID id: String) {
        if selection?.serverID == id { disconnect() }
        browser.removeManualServer(id: id)
    }

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

        if client.status.hasLiveData {
            isDataStale = false
            preferences.lastWorkspace = selection
        }
    }

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

        isDataStale = false
        preferences.lastWorkspace = target

        if remember {
            do {
                try passcodes.save(
                    passcode, serverID: prompt.serverID, workspaceID: prompt.workspaceID
                )
                storedPasscodeSelections.insert(target)
            } catch {
                credentialError = CredentialError(
                    action: "Cuety connected, but could not save the passcode to your Keychain.",
                    reason: error.operatorDescription
                )
            }
        }

        passcodePrompt = nil
    }

    func disconnect() {
        startupTask?.cancel()
        autoConnectIsArmed = false

        passcodePrompt = nil
        client.disconnect()
        selection = nil
    }

    func forgetPasscode(for selection: WorkspaceSelection) {
        do {
            try passcodes.remove(
                serverID: selection.serverID, workspaceID: selection.workspaceID
            )
            storedPasscodeSelections.remove(selection)
        } catch {
            credentialError = CredentialError(
                action: "Cuety could not remove that passcode from your Keychain.",
                reason: error.operatorDescription
            )
        }
    }

    func forgetAllPasscodes() {
        do {
            try passcodes.removeAll()
            storedPasscodeSelections.removeAll()
        } catch {
            credentialError = CredentialError(
                action: "Cuety could not clear the saved passcodes from your Keychain.",
                reason: error.operatorDescription
            )
        }
    }

    func refreshStoredPasscodes() async {
        var selections: Set<WorkspaceSelection> = []
        for server in browser.servers {
            selections.formUnion(server.workspaces.map { workspace in
                WorkspaceSelection(serverID: server.id, workspaceID: workspace.uniqueID)
            })
        }

        let passcodes = self.passcodes
        let found = await Task.detached(priority: .utility) {
            passcodes.selectionsWithPasscodes(Set(selections))
        }.value

        guard !Task.isCancelled else { return }
        storedPasscodeSelections = found
    }

    private func workspaceName(for selection: WorkspaceSelection) -> String? {
        browser.server(withID: selection.serverID)?
            .workspaces.first { $0.uniqueID == selection.workspaceID }?
            .displayName
    }

    var standbyCue: Cue? {
        client.liveCue
    }

    var dockBadgeLabel: String? {
        guard preferences.showsDockBadge else { return nil }
        return standbyCue?.displayNumber
    }

    func togglePresentationMode() {
#if os(macOS)
        setPresenting(!isPresenting)
#endif
    }

    func setPresenting(_ presenting: Bool) {
#if os(macOS)
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
#else
        _ = presenting
#endif
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleDrawer() {
        withAnimation(Motion.chrome.unlessMotionIsReduced) {
            preferences.showsDrawer.toggle()
        }
    }

    /// The drawer's height as a step count: zero is collapsed to its handle,
    /// and every step above that is one more row either side of the playhead.
    var drawerStep: Int {
        preferences.showsDrawer ? preferences.drawerRowCount : 0
    }

    /// Sets the drawer's height to a step, collapsing it at anything below one.
    func resizeDrawer(toStep step: Int) {
        let step = max(0, step)
        guard step != drawerStep else { return }

        withAnimation(Motion.drawerShift.unlessMotionIsReduced) {
            preferences.showsDrawer = step > 0
            if step > 0 { preferences.drawerRowCount = step }
        }
    }

    func toggleKeepAwake() {
        preferences.keepsDisplayAwake.toggle()
        displaySleepBlocker.setEnabled(preferences.keepsDisplayAwake)
    }

    func togglePerformanceMode() {
        preferences.performanceMode.toggle()
    }
}
