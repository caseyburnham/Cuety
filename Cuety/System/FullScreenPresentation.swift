#if os(macOS)
import AppKit
import SwiftUI

struct FullScreenPresentation: NSViewRepresentable {
    let isPresenting: Bool

    let onFullScreenChange: (Bool) -> Void

    final class Coordinator {
        private var observations: [NotificationCenter.ObservationToken] = []

        private weak var observedWindow: NSWindow?

        private var isTransitioning = false

        private var pendingUpdate: Task<Void, Never>?

        private let pointer = PointerHider()

        var onFullScreenChange: (Bool) -> Void = { _ in }

        func observe(_ window: NSWindow) {
            // AppKit owns the transition; synchronize state from its completion notifications.
            guard observedWindow !== window else { return }
            observedWindow = window

            let center = NotificationCenter.default
            observations = [
                center.addObserver(
                    of: window, for: NSWindow.WillEnterFullScreenMessage.self
                ) { [weak self] _ in self?.isTransitioning = true },

                center.addObserver(
                    of: window, for: NSWindow.WillExitFullScreenMessage.self
                ) { [weak self] _ in self?.isTransitioning = true },

                center.addObserver(
                    of: window, for: NSWindow.DidEnterFullScreenMessage.self
                ) { [weak self] _ in self?.settle(isFullScreen: true) },

                center.addObserver(
                    of: window, for: NSWindow.DidExitFullScreenMessage.self
                ) { [weak self] _ in self?.settle(isFullScreen: false) },

                center.addObserver(
                    of: window, for: NSWindow.WillCloseMessage.self
                ) { [weak self] _ in self?.pointer.end() },
            ]
        }

        func scheduleApply(isPresenting presenting: Bool, to view: NSView) {
            pendingUpdate?.cancel()
            pendingUpdate = Task { @MainActor [weak self, weak view] in
                guard let self, let view, let window = view.window else { return }
                self.observe(window)
                self.apply(isPresenting: presenting, to: window)
            }
        }

        private func apply(isPresenting presenting: Bool, to window: NSWindow) {
            guard window.styleMask.contains(.fullScreen) != presenting else { return }
            guard !isTransitioning else { return }
            window.toggleFullScreen(nil)
        }

        private func settle(isFullScreen: Bool) {
            isTransitioning = false
            if isFullScreen, let observedWindow {
                pointer.begin(in: observedWindow)
            } else {
                pointer.end()
            }
            onFullScreenChange(isFullScreen)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isPresenting = isPresenting
        let coordinator = context.coordinator
        coordinator.onFullScreenChange = onFullScreenChange

        coordinator.scheduleApply(isPresenting: isPresenting, to: view)
    }
}
#else
import SwiftUI

struct FullScreenPresentation: View {
    let isPresenting: Bool
    let onFullScreenChange: (Bool) -> Void

    var body: some View {
        Color.clear
    }
}
#endif
