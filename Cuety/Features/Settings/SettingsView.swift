import SwiftUI

/// Cuety's Settings window.
///
/// Four tabs, split by what the operator is thinking about rather than by which
/// type owns the value: how the app behaves, how the cue reads, what metadata
/// sits under it, and how Cuety talks to QLab.
struct SettingsView: View {
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
        // A fixed size because each tab is a `Form`: letting the window resize
        // to its content would make it jump as the operator moves between tabs.
        .frame(width: 540, height: 440)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
