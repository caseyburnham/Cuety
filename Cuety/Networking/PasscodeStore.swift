import Foundation
import Security
import os

nonisolated protocol PasscodeStoring: Sendable {
    func passcode(serverID: String, workspaceID: String) -> String?
    func hasPasscode(serverID: String, workspaceID: String) -> Bool
    func selectionsWithPasscodes(
        _ selections: Set<WorkspaceSelection>
    ) -> Set<WorkspaceSelection>
    func save(_ passcode: String, serverID: String, workspaceID: String) throws
    func remove(serverID: String, workspaceID: String) throws
    func removeAll() throws
}

nonisolated extension PasscodeStoring {
    func selectionsWithPasscodes(
        _ selections: Set<WorkspaceSelection>
    ) -> Set<WorkspaceSelection> {
        Set(selections.filter { hasPasscode(
            serverID: $0.serverID, workspaceID: $0.workspaceID
        ) })
    }
}

nonisolated struct PasscodeStore: PasscodeStoring {
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "PasscodeStore")

    private static let service = "Cuety QLab Passcodes"
    private static let legacyService = "com.ivxx.Cuety.qlab-passcode"

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

    private func account(serverID: String, workspaceID: String) -> String {
        "\(serverID)|\(workspaceID)"
    }

    private func baseQuery(
        serverID: String, workspaceID: String, service: String = Self.service
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(serverID: serverID, workspaceID: workspaceID),
        ]
    }


    func passcode(serverID: String, workspaceID: String) -> String? {
        for service in [Self.service, Self.legacyService] {
            var query = baseQuery(
                serverID: serverID, workspaceID: workspaceID, service: service
            )
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            if status == errSecSuccess, let data = item as? Data,
               let passcode = String(data: data, encoding: .utf8) {
                if service == Self.legacyService {
                    migrateLegacyPasscode(
                        passcode, serverID: serverID, workspaceID: workspaceID
                    )
                }
                return passcode
            }

            if status != errSecItemNotFound {
                logger.warning("Keychain read failed with status \(status)")
            }
        }
        return nil
    }

    private func migrateLegacyPasscode(
        _ passcode: String, serverID: String, workspaceID: String
    ) {
        do {
            try save(passcode, serverID: serverID, workspaceID: workspaceID)
            try remove(
                serverID: serverID, workspaceID: workspaceID, service: Self.legacyService
            )
        } catch {
            logger.warning("Could not migrate a legacy passcode to the new Keychain service")
        }
    }

    func hasPasscode(serverID: String, workspaceID: String) -> Bool {
        selectionsWithPasscodes([
            WorkspaceSelection(serverID: serverID, workspaceID: workspaceID)
        ]).isEmpty == false
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
        var found: Set<WorkspaceSelection> = []

        for service in [Self.service, Self.legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            if status == errSecSuccess {
                let attributes = (item as? [[String: Any]]) ?? []
                for attribute in attributes {
                    guard let account = attribute[kSecAttrAccount as String] as? String,
                          let selection = selectionsByAccount[account]
                    else { continue }
                    found.insert(selection)
                }
            } else if status != errSecItemNotFound {
                logger.warning("Keychain batch read failed with status \(status)")
            }
        }

        return found
    }


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
        try remove(
            serverID: serverID, workspaceID: workspaceID, service: Self.service
        )
        try remove(
            serverID: serverID, workspaceID: workspaceID, service: Self.legacyService
        )
    }

    private func remove(
        serverID: String, workspaceID: String, service: String
    ) throws {
        let status = SecItemDelete(
            baseQuery(
                serverID: serverID, workspaceID: workspaceID, service: service
            ) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    func removeAll() throws {
        for service in [Self.service, Self.legacyService] {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)

            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain(status)
            }
        }
    }
}
