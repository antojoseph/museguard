import SwiftUI

/// Entry point. Sentinel Pet runs as a menu-bar agent (no Dock icon, see
/// `LSUIElement` in Info.plist). The floating "pet" overlay is owned by the
/// `AppDelegate`, while the menu-bar item lives here.
@main
struct SentinelPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Sentinel Pet", systemImage: "shield.lefthalf.filled") {
            MenuBarContent()
        }
    }
}
