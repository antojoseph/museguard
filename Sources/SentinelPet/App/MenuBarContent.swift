import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown. Most items are placeholders for now and
/// get wired up in later milestones (monitoring, settings, privacy controls).
struct MenuBarContent: View {
    var body: some View {
        Text("Sentinel Pet")
            .font(.headline)

        Button("Pause monitoring") {}
            .disabled(true)

        Button("Settings…") {}
            .disabled(true)

        Divider()

        Button("Quit Sentinel Pet") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
