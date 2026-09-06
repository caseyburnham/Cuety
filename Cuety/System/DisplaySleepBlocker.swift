@preconcurrency import Foundation
import os

/// Keeps the display awake while enabled.
///
/// Uses `ProcessInfo.beginActivity(options:reason:)` with
/// `.idleDisplaySleepDisabled` — the documented Foundation API for this, so
/// there is no IOKit power-assertion plumbing to get wrong. The returned token
/// must be held for the lifetime of the activity and handed back exactly once.
@MainActor
final class DisplaySleepBlocker {
    private let logger = Logger(subsystem: "com.caseyburnham.Cuety", category: "KeepAwake")

    /// The opaque activity token, non-nil exactly when the block is active.
    private var token: NSObjectProtocol?

    var isEnabled: Bool { token != nil }

    func setEnabled(_ enabled: Bool) {
        enabled ? begin() : end()
    }

    private func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            // `.userInitiated` because someone asked for this explicitly, and
            // it also opts out of App Nap while the window sits idle showing a
            // cue number.
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "Cuety is displaying the current cue"
        )
        logger.info("Display sleep blocked")
    }

    private func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
        logger.info("Display sleep block released")
    }

    deinit {
        // Releasing the assertion on teardown matters: leaving it held would
        // keep a machine awake after Cuety is gone. `endActivity` is safe to
        // call from `deinit` and this is the last chance to do it.
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
