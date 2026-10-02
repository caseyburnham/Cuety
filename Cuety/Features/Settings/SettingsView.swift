import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 540

    private enum Pane: Hashable, CaseIterable {
        case general, display, details, connection

        static let shortest = [
            GeneralSettingsView.settingsHeight,
            DisplaySettingsView.settingsHeight,
            DetailPillSettingsView.settingsHeight,
            ConnectionSettingsView.settingsHeight
        ].min() ?? 0
    }

    @State private var pane: Pane = .general

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
#if os(macOS)
        .frame(
            minWidth: Self.width,
            maxWidth: Self.width,
            minHeight: Pane.shortest,
            maxHeight: .infinity
        )
#else
        .frame(
            maxWidth: .infinity,
            minHeight: Pane.shortest,
            maxHeight: .infinity
        )
#endif
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview)
        .frame(width: SettingsView.width, height: GeneralSettingsView.settingsHeight)
}
