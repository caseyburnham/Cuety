import Foundation

/// A private defaults domain for one test, deleted from disk when the last
/// owner lets it go. A plain `UserDefaults(suiteName:)` leaves its plist
/// behind in ~/Library/Preferences after every run.
nonisolated final class EphemeralDefaults: UserDefaults, @unchecked Sendable {
    private let domain: String

    init() {
        let domain = "CuetyTests.\(UUID().uuidString)"
        self.domain = domain
        // Only a name reserved by the system can make this fail.
        super.init(suiteName: domain)!
    }

    deinit {
        removePersistentDomain(forName: domain)
    }
}
