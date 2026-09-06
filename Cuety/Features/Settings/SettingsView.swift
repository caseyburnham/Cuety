import SwiftUI

/// Cuety's Settings window.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Milestone 8 replaces this with the four real tabs.
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Picker("Appearance", selection: Bindable(model.preferences).appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 320)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
