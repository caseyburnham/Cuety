import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    static let width: CGFloat = 540

    private enum Pane: Hashable, CaseIterable {
        case general, display, details, connection

        var height: CGFloat {
            switch self {
            case .general: GeneralSettingsView.settingsHeight
            case .display: DisplaySettingsView.settingsHeight
            case .details: DetailPillSettingsView.settingsHeight
            case .connection: ConnectionSettingsView.settingsHeight
            }
        }

        static var shortest: CGFloat { allCases.map(\.height).min() ?? 0 }
    }

    @State private var pane: Pane = .general

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettingsView()
            }

            Tab("Display", systemImage: "textformat.size", value: Pane.display) {
                DisplaySettingsView()
            }

            Tab("Details", systemImage: "capsule.on.rectangle", value: Pane.details) {
                DetailPillSettingsView()
            }

            Tab("Connection", systemImage: "network", value: Pane.connection) {
                ConnectionSettingsView()
            }
        }
        .frame(
            minWidth: Self.width,
            maxWidth: Self.width,
            minHeight: Pane.shortest,
            maxHeight: .infinity
        )
#if os(macOS)
        .background(
            SettingsWindowHeight(
                height: pane.height,
                isAnimated: !reduceMotion
            )
        )
#endif
    }
}

#if os(macOS)
private struct SettingsWindowHeight: NSViewRepresentable {
    let height: CGFloat

    let isAnimated: Bool

    @MainActor
    final class Coordinator {
        var hasSized = false
        private var pendingUpdate: Task<Void, Never>?

        func scheduleUpdate(
            for view: NSView,
            height: CGFloat,
            isAnimated: Bool
        ) {
            pendingUpdate?.cancel()
            pendingUpdate = Task { @MainActor [weak self, weak view] in
                guard !Task.isCancelled,
                      let self, let view, let window = view.window
                else { return }
                SettingsWindowHeight.apply(
                    height: height,
                    paneHeight: view.frame.size.height,
                    to: window,
                    animated: isAnimated && self.hasSized
                )
                self.hasSized = true
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        let isAnimated = isAnimated
        context.coordinator.scheduleUpdate(
            for: view,
            height: height,
            isAnimated: isAnimated
        )
    }

    @MainActor
    private static func apply(
        height: CGFloat, paneHeight: CGFloat, to window: NSWindow, animated: Bool
    ) {
        let delta = height - paneHeight
        guard abs(delta) > 0.5 else { return }

        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta

        guard animated else {
            window.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        }
    }
}
#endif

#Preview {
    SettingsView()
        .environment(AppModel())
        .frame(width: SettingsView.width, height: GeneralSettingsView.settingsHeight)
}
