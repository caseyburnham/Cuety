@preconcurrency import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// Keeps the screen on while Cuety shows the standby cue. The Mac holds a
/// process activity; the iPad disables its idle timer, which only applies
/// while Cuety is in the foreground.
@MainActor
final class DisplaySleepBlocker {
    private let logger = Logger(subsystem: "org.arvadacenter.Cuety", category: "KeepAwake")

#if os(macOS)
    private var token: NSObjectProtocol?
#else
    private var isBlocking = false
#endif

    func setEnabled(_ enabled: Bool) {
        enabled ? begin() : end()
    }

#if os(macOS)
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
#else
    private func begin() {
        guard !isBlocking else { return }
        isBlocking = true
        UIApplication.shared.isIdleTimerDisabled = true
        logger.info("Idle timer disabled")
    }

    private func end() {
        guard isBlocking else { return }
        isBlocking = false
        UIApplication.shared.isIdleTimerDisabled = false
        logger.info("Idle timer restored")
    }
#endif
}
