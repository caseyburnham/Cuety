import Foundation
import Testing

@testable import Cuety

/// Saved-passcode behaviour: what the operator is told, what they see, and
/// what stays separate from what.
///
/// Every test here injects a stub store. None of them touch the real Keychain
/// — reaching into the developer's own credentials to test credential handling
/// would be its own kind of wrong, and this project has already written test
/// data into real preferences once.
@Suite("Stored passcodes")
@MainActor
struct StoredPasscodeTests {
    /// A model whose browser can see one workspace, with a passcode stored for
    /// it, discovered the way the app discovers it.
    ///
    /// Built through `refreshStoredPasscodes()` rather than by poking the
    /// observable set directly, so the setup exercises the same path the app
    /// uses and the tests are not resting on a hook that only they call.
    private func makeModel(
        _ store: StubPasscodeStore, withStoredPasscode: Bool = true
    ) throws -> (model: AppModel, target: WorkspaceSelection) {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = AppModel(
            preferences: Preferences(defaults: defaults), passcodes: store
        )

        let serverID = QLabServer.localhost().id
        var server = try #require(model.browser.server(withID: serverID))
        server.workspaces = [
            QLabWorkspaceInfo(
                uniqueID: "W", displayName: "Act One",
                port: nil, udpReplyPort: nil, version: nil, hasPasscode: nil
            ),
        ]
        model.browser.update(server)

        let target = WorkspaceSelection(serverID: serverID, workspaceID: "W")
        if withStoredPasscode {
            try store.save("hunter2", serverID: serverID, workspaceID: "W")
        }
        model.refreshStoredPasscodes()

        return (model, target)
    }

    @Test("Forget removes the credential and the row together")
    func forgetUpdatesObservableState() throws {
        let store = StubPasscodeStore()
        let (model, target) = try makeModel(store)
        try #require(model.storedPasscodeSelections.contains(target))

        model.forgetPasscode(for: target)

        // Both, in one action. Settings reads the observable set, so this is
        // what makes the row disappear — reading the Keychain from a computed
        // view property gave Forget nothing to invalidate.
        #expect(store.stored.isEmpty)
        #expect(!model.storedPasscodeSelections.contains(target))
        #expect(model.credentialError == nil)
    }

    @Test("A Forget that fails says so, and does not pretend the row is gone")
    func forgetFailureIsSurfaced() throws {
        let store = StubPasscodeStore()
        let (model, target) = try makeModel(store)
        store.removeError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        model.forgetPasscode(for: target)

        // `try?` used to swallow this, so a Forget that failed looked
        // identical to one that worked.
        let error = try #require(model.credentialError)
        #expect(error.message.contains("could not remove"))
        // And the row stays, because the credential is still there.
        #expect(model.storedPasscodeSelections.contains(target))
        #expect(store.hasPasscode(serverID: target.serverID, workspaceID: target.workspaceID))
    }

    @Test("Forget All clears the credentials and the rows")
    func forgetAllSucceeds() throws {
        let store = StubPasscodeStore()
        let (model, target) = try makeModel(store)
        try #require(model.storedPasscodeSelections.contains(target))

        model.forgetAllPasscodes()

        #expect(store.stored.isEmpty)
        #expect(model.storedPasscodeSelections.isEmpty)
        #expect(model.credentialError == nil)
    }

    @Test("A Forget All that fails says so")
    func forgetAllFailureIsSurfaced() throws {
        let store = StubPasscodeStore()
        let (model, target) = try makeModel(store)
        store.removeAllError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        model.forgetAllPasscodes()

        let error = try #require(model.credentialError)
        #expect(error.message.contains("could not clear"))
        #expect(model.storedPasscodeSelections.contains(target))
    }

    /// The Keychain's own message is the useful half, and
    /// `PasscodeStore.Failure` already words it for an operator. Falling back
    /// to `localizedDescription` would report "The operation couldn't be
    /// completed", which tells nobody anything.
    @Test("The reported reason comes from the Keychain, not from Swift")
    func failureReasonIsOperatorReadable() throws {
        let store = StubPasscodeStore()
        let (model, target) = try makeModel(store)
        store.removeError = PasscodeStore.Failure.keychain(errSecAuthFailed)

        model.forgetPasscode(for: target)

        let error = try #require(model.credentialError)
        #expect(error.reason == PasscodeStore.Failure.keychain(errSecAuthFailed).description)
        #expect(!error.reason.contains("couldn't be completed"))
    }

    @Test("Rebuilding the set finds credentials for workspaces that become visible")
    func refreshFindsNewlyVisibleWorkspaces() throws {
        let store = StubPasscodeStore()
        // Nothing stored at setup, so the set starts empty.
        let (model, target) = try makeModel(store, withStoredPasscode: false)
        try #require(model.storedPasscodeSelections.isEmpty)

        // A credential from an earlier session, for a machine that has only
        // just come back on the network.
        try store.save("hunter2", serverID: target.serverID, workspaceID: target.workspaceID)
        model.refreshStoredPasscodes()

        #expect(model.storedPasscodeSelections.contains(target))
    }
}

/// A credential store a test can make fail.
///
/// The real ``PasscodeStore`` cannot be made to fail on demand, which is how
/// its error paths came to be `try?` and silent — untestable behaviour tends
/// to stay untested.
private final class StubPasscodeStore: PasscodeStoring, @unchecked Sendable {
    /// Keyed by `[serverID, workspaceID]`, so the key order is explicit.
    var stored: [[String]: String] = [:]
    var saveError: (any Error)?
    var removeError: (any Error)?
    var removeAllError: (any Error)?

    func passcode(serverID: String, workspaceID: String) -> String? {
        stored[[serverID, workspaceID]]
    }

    func hasPasscode(serverID: String, workspaceID: String) -> Bool {
        passcode(serverID: serverID, workspaceID: workspaceID) != nil
    }

    func save(_ passcode: String, serverID: String, workspaceID: String) throws {
        if let saveError { throw saveError }
        stored[[serverID, workspaceID]] = passcode
    }

    func remove(serverID: String, workspaceID: String) throws {
        if let removeError { throw removeError }
        stored.removeValue(forKey: [serverID, workspaceID])
    }

    func removeAll() throws {
        if let removeAllError { throw removeAllError }
        stored.removeAll()
    }
}
