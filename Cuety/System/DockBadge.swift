import AppKit
import Observation

@MainActor
final class DockBadge {
    private var task: Task<Void, Never>?

    func follow(_ label: @escaping @Sendable @MainActor () -> String?) {
        guard task == nil else { return }
        task = Task { @MainActor in
            var applied: String??
            for await value in Observations(label) {
                guard applied != value else { continue }
                applied = value
                NSApp.dockTile.badgeLabel = value
            }
        }
    }

}
