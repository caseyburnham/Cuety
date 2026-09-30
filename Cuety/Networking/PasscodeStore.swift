import Foundation
import Security
import os

nonisolated protocol PasscodeStoring: Sendable {
    func passcode(serverID: String, workspaceID: String) -> String?
    /// Which of `selections` have a stored passcode, found in one lookup.
    func selectionsWithPasscodes(
        _ selections: Set<WorkspaceSelection>
    ) -> Set<WorkspaceSelection>
    func save(_ passcode: String, serverID: String, workspaceID: String) throws
    func remove(serverID: String, workspaceID: String) throws
    func removeAll() throws
}

nonisolated extension PasscodeStoring {
    func hasPasscode(serverID: String, workspaceID: String) -> Bool {
        let selection = WorkspaceSelection(serverID: serverID, workspaceID: workspaceID)
        return selectionsWithPasscodes([selection]).contains(selection)
    }
}

nonisolated struct PasscodeStore: PasscodeStoring {
    private let logger = Logger(category: "PasscodeStore")

    private static let service = "Cuety QLab Passcodes"

    nonisolated enum Failure: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error \(status)."
            }
        }
    }

    private func account(serverID: String, workspaceID: String) -> String {
        "\(serverID)|\(workspaceID)"
    }

    /// Every item Cuety stores. The Mac uses its file-based keychain: the data
    /// protection keychain needs a keychain access group entitlement, which
    /// Cuety is not signed with, and fails with errSecMissingEntitlement.
    private var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
    }

    private func itemQuery(serverID: String, workspaceID: String) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] = account(serverID: serverID, workspaceID: workspaceID)
        return query
    }

    func passcode(serverID: String, workspaceID: String) -> String? {
        var query = itemQuery(serverID: serverID, workspaceID: workspaceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status != errSecItemNotFound {
            logger.warning("Keychain read failed with status \(status)")
        }
        return nil
    }

    func selectionsWithPasscodes(
        _ selections: Set<WorkspaceSelection>
    ) -> Set<WorkspaceSelection> {
        guard !selections.isEmpty else { return [] }

        let selectionsByAccount = Dictionary(
            uniqueKeysWithValues: selections.map { selection in
                (account(serverID: selection.serverID, workspaceID: selection.workspaceID), selection)
            }
        )

        var query = serviceQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.warning("Keychain batch read failed with status \(status)")
            }
            return []
        }

        let attributes = (item as? [[String: Any]]) ?? []
        return Set(attributes.compactMap { attribute in
            (attribute[kSecAttrAccount as String] as? String).flatMap { selectionsByAccount[$0] }
        })
    }

    func save(_ passcode: String, serverID: String, workspaceID: String) throws {
        guard !passcode.isEmpty else {
            try remove(serverID: serverID, workspaceID: workspaceID)
            return
        }

        let query = itemQuery(serverID: serverID, workspaceID: workspaceID)
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
        try delete(itemQuery(serverID: serverID, workspaceID: workspaceID))
    }

    func removeAll() throws {
        try delete(serviceQuery)
    }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }
}
