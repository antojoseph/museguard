import AppKit

/// Owns the lifetime of the floating pet overlay. Kept as a strong reference so
/// the panel and its view model survive for the whole app session.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = SentinelPetRuntime.shared
    private var overlay: PetOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the companion out of the Dock. First-run setup can take focus.
        NSApp.setActivationPolicy(.accessory)

        runtime.refreshAccessibilityStatus()
        runtime.refreshScreenCaptureStatus()
        LocalModelService.shared.start()
        runtime.startBrowserBridge()

        let overlay = PetOverlayController(viewModel: runtime.petViewModel)
        overlay.show()
        self.overlay = overlay
        // Show access choices once at the installed location. Launching a
        // different copy for verification must not mark the install as set up.
        let appPath = Bundle.main.bundleURL.standardizedFileURL.path
        if LocalModelService.shared.supportsInstallation,
           UserDefaults.standard.string(forKey: "museFirstRunPermissionsPath") != appPath {
            UserDefaults.standard.set(appPath, forKey: "museFirstRunPermissionsPath")
            runtime.showSettings()
        }
        #if MUSE_DEVELOPMENT
        if ProcessInfo.processInfo.arguments.contains("--chat-corner-check") { overlay.showChatCornerCheck() }
        if ProcessInfo.processInfo.arguments.contains("--mock-lab") { MockLab.shared.show() }
        if ProcessInfo.processInfo.arguments.contains("--studio") { GuardianStudio.shared.show() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stopBrowserBridge()
        UnrealCharacterRenderer.shared.stop()
        LocalModelService.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard LocalModelService.shared.isInstalling else { return .terminateNow }
        Task {
            await LocalModelService.shared.finishInstallationOnQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime.refreshAccessibilityStatus()
        runtime.refreshScreenCaptureStatus()
        LocalModelService.shared.start()
    }
}
