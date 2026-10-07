import Foundation
import Testing

@testable import Cuety

@Suite("Stored passcodes")
@MainActor
struct StoredPasscodeTests {
    private func makeModel(
        _ store: TestPasscodeStore, withStoredPasscode: Bool = true
    ) async throws -> (model: AppModel, target: WorkspaceSelection) {
        let defaults = EphemeralDefaults()
        let model = AppModel(
            preferences: Preferences(defaults: defaults), passcodes: store
        )

        let serverID = QLabServer.localhost().id
        var server = try #require(model.browser.server(withID: serverID))
        server.workspaces = [
            QLabWorkspaceInfo(
                uniqueID: "W", displayName: "Act One",
                port: nil, version: nil
            ),
        ]
        model.browser.update(server)

        let target = WorkspaceSelection(serverID: serverID, workspaceID: "W")
        if withStoredPasscode {
            try store.save("hunter2", serverID: serverID, workspaceID: "W")
        }
        await model.refreshStoredPasscodes()

        return (model, target)
    }

    @Test("Forget removes the credential and the row together")
    func forgetUpdatesObservableState() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        try #require(model.storedPasscodeSelections.contains(target))

        try model.forgetPasscode(for: target)

        #expect(store.stored.isEmpty)
        #expect(!model.storedPasscodeSelections.contains(target))
    }

    @Test("A Forget that fails says so, and does not pretend the row is gone")
    func forgetFailureIsSurfaced() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        store.removeError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        let error = try #require(throws: AppModel.CredentialError.self) {
            try model.forgetPasscode(for: target)
        }
        #expect(error.message.contains("could not remove"))
        #expect(model.storedPasscodeSelections.contains(target))
        #expect(store.selectionsWithPasscodes([target]).contains(target))
    }

    @Test("Forget All clears the credentials and the rows")
    func forgetAllSucceeds() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        try #require(model.storedPasscodeSelections.contains(target))

        try model.forgetAllPasscodes()

        #expect(store.stored.isEmpty)
        #expect(model.storedPasscodeSelections.isEmpty)
    }

    @Test("A Forget All that fails says so")
    func forgetAllFailureIsSurfaced() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        store.removeAllError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        let error = try #require(throws: AppModel.CredentialError.self) {
            try model.forgetAllPasscodes()
        }
        #expect(error.message.contains("could not clear"))
        #expect(model.storedPasscodeSelections.contains(target))
    }

    @Test("The reported reason comes from the Keychain, not from Swift")
    func failureReasonIsOperatorReadable() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        store.removeError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        let error = try #require(throws: AppModel.CredentialError.self) {
            try model.forgetPasscode(for: target)
        }
        #expect(error.reason == PasscodeStore.Failure.keychain(errSecAuthFailed).localizedDescription)
        #expect(!error.reason.contains("couldn't be completed"))
    }

    @Test("A rejected passcode that cannot be removed is reported to the connection flow")
    func rejectedPasscodeRemovalFailureIsSurfaced() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store)
        store.removeError = PasscodeStore.Failure.keychain(errSecAuthFailed)
        model.selection = target

        model.client.onPasscodeRequired?(true)

        let error = try #require(model.credentialError)
        #expect(error.message.contains("could not remove"))
        #expect(model.passcodePrompt?.wasRejected == true)
    }

    @Test("Rebuilding the set finds credentials for workspaces that become visible")
    func refreshFindsNewlyVisibleWorkspaces() async throws {
        let store = TestPasscodeStore()
        let (model, target) = try await makeModel(store, withStoredPasscode: false)
        try #require(model.storedPasscodeSelections.isEmpty)

        try store.save("hunter2", serverID: target.serverID, workspaceID: target.workspaceID)
        await model.refreshStoredPasscodes()

        #expect(model.storedPasscodeSelections.contains(target))
    }

}

final class TestPasscodeStore: PasscodeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [[String]: String] = [:]
    private var saveFailure: (any Error)?
    private var removeFailure: (any Error)?
    private var removeAllFailure: (any Error)?

    var stored: [[String]: String] { withLock { storedValues } }

    var saveError: (any Error)? {
        get { withLock { saveFailure } }
        set { withLock { saveFailure = newValue } }
    }

    var removeError: (any Error)? {
        get { withLock { removeFailure } }
        set { withLock { removeFailure = newValue } }
    }

    var removeAllError: (any Error)? {
        get { withLock { removeAllFailure } }
        set { withLock { removeAllFailure = newValue } }
    }

    func passcode(serverID: String, workspaceID: String) -> String? {
        withLock { storedValues[[serverID, workspaceID]] }
    }

    func selectionsWithPasscodes(_ selections: Set<WorkspaceSelection>) -> Set<WorkspaceSelection> {
        withLock {
            selections.filter {
                storedValues[[$0.serverID, $0.workspaceID]] != nil
            }
        }
    }

    func save(_ passcode: String, serverID: String, workspaceID: String) throws {
        try withLock {
            if let saveFailure { throw saveFailure }
            storedValues[[serverID, workspaceID]] = passcode
        }
    }

    func remove(serverID: String, workspaceID: String) throws {
        try withLock {
            if let removeFailure { throw removeFailure }
            storedValues.removeValue(forKey: [serverID, workspaceID])
        }
    }

    func removeAll() throws {
        try withLock {
            if let removeAllFailure { throw removeAllFailure }
            storedValues.removeAll()
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
