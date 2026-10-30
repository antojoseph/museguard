import AppKit
import ApplicationServices
import Foundation

/// Native detection is warning-only. macOS global event monitors observe a
/// paste after it is delivered; Chrome's content guard prevents insertion.
/// No clipboard poll, event tap, raw-content log, model call or extra permission.
@MainActor
final class NativeSecretPasteMonitor {
    private let detector: SecretDetector
    private var monitor: Any?
    private var lastPasteTime: TimeInterval = -.infinity

    init(detector: SecretDetector = SecretDetector()) { self.detector = detector }

    @discardableResult
    func start(isEnabled: @escaping () -> Bool,
        shouldIgnoreApp: @escaping (NSRunningApplication) -> Bool = { _ in false },
        onDetection: @escaping (pid_t, SecretDetection) -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // AppKit delivers global-monitor callbacks on the main thread.
            MainActor.assumeIsolated {
                guard let self, isEnabled(), Self.isPaste(event),
                      event.timestamp - self.lastPasteTime >= 0.5,
                      let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      app.bundleIdentifier?.hasPrefix("com.google.Chrome") != true,
                      !shouldIgnoreApp(app) else { return }
                self.lastPasteTime = event.timestamp
                // Reading occurs only in response to this Command+V. The
                // detector returns safe metadata synchronously; text is never
                // retained by the monitor or handed to the callback.
                guard let text = NSPasteboard.general.string(forType: .string),
                      let detection = self.detector.detect(text),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                onDetection(app.processIdentifier, detection)
            }
        }
        return monitor != nil
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; lastPasteTime = -.infinity
    }
    static func isPaste(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !event.isARepeat && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) &&
            (event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v")
    }
}
