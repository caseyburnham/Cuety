import Foundation
import os

nonisolated extension Logger {
    /// A logger under the app's bundle identifier, so every category shares
    /// one subsystem to filter by in Console.
    init(category: String) {
        self.init(subsystem: Bundle.main.bundleIdentifier ?? "org.arvadacenter.Cuety", category: category)
    }
}
