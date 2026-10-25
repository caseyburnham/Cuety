import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 540
    static let minHeight: CGFloat = GeneralSettingsView.settingsHeight

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }

            Tab("Display", systemImage: "textformat.size") {
                DisplaySettingsView()
            }

            Tab("Details", systemImage: "capsule.on.rectangle") {
                DetailPillSettingsView()
            }

            Tab("Connection", systemImage: "network") {
                ConnectionSettingsView()
            }
        }
#if os(macOS)
        .frame(
            minWidth: Self.width,
            maxWidth: Self.width,
            minHeight: Self.minHeight,
            maxHeight: .infinity
        )
#else
        .frame(
            maxWidth: .infinity,
            minHeight: Self.minHeight,
            maxHeight: .infinity
        )
#endif
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview)
        .frame(width: SettingsView.width, height: SettingsView.minHeight)
}
