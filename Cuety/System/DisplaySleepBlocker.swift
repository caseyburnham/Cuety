@preconcurrency import Foundation
import os

@MainActor
final class DisplaySleepBlocker {
    private let logger = Logger(subsystem: "com.ivxx.Cuety", category: "KeepAwake")

    private var token: NSObjectProtocol?

    func setEnabled(_ enabled: Bool) {
        enabled ? begin() : end()
    }

    private func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
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
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
