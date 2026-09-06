import Foundation
import Security
import os

/// Stores QLab workspace passcodes in the Keychain.
///
/// The Keychain rather than `UserDefaults`: these are credentials to someone
/// else's show file. A sandboxed app gets its own Keychain access group from its
/// application identifier, so this needs no entitlement.
nonisolated struct PasscodeStore {
    private let logger = Logger(subsystem: "com.caseyburnham.Cuety", category: "PasscodeStore")

    /// The Keychain service name all Cuety items share.
    private static let service = "com.caseyburnham.Cuety.qlab-passcode"

    /// Errors surfaced to the passcode sheet.
    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)

        var description: String {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error \(status)."
            }
        }
    }

    /// Scopes a passcode to one workspace on one server, so two shows on the
    /// same machine don't share credentials.
    private func account(serverID: String, workspaceID: String) -> String {
        "\(serverID)|\(workspaceID)"
    }

    private func baseQuery(serverID: String, workspaceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(serverID: serverID, workspaceID: workspaceID),
        ]
    }

    // MARK: - Read

    func passcode(serverID: String, workspaceID: String) -> String? {
        var query = baseQuery(serverID: serverID, workspaceID: workspaceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.warning("Keychain read failed with status \(status)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPasscode(serverID: String, workspaceID: String) -> Bool {
        passcode(serverID: serverID, workspaceID: workspaceID) != nil
    }

    // MARK: - Write

    /// Saves or replaces a passcode. An empty string removes it, so clearing
    /// the field in the sheet does the obvious thing.
    func save(_ passcode: String, serverID: String, workspaceID: String) throws {
        guard !passcode.isEmpty else {
            try remove(serverID: serverID, workspaceID: workspaceID)
            return
        }

        let query = baseQuery(serverID: serverID, workspaceID: workspaceID)
        let data = Data(passcode.utf8)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            // `afterFirstUnlock` rather than `whenUnlocked`: Cuety may be
            // relaunched by a login item before anyone touches the machine, and
            // reconnecting automatically is the point.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw Failure.keychain(addStatus)
            }
        default:
            throw Failure.keychain(updateStatus)
        }
    }

    func remove(serverID: String, workspaceID: String) throws {
        let status = SecItemDelete(
            baseQuery(serverID: serverID, workspaceID: workspaceID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    /// Removes every passcode Cuety has stored.
    func removeAll() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ] as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }
}
