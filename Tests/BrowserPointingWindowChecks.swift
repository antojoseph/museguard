import AppKit

// Geometry-only checks compile the controller without starting an app/window.
@MainActor final class UnrealCharacterRenderer {
    static let shared = UnrealCharacterRenderer()
    func setPointingDirection(_ direction: Double?) {}
}
enum BrowserBridgeServer { static let directory = URL(fileURLWithPath: NSTemporaryDirectory()) }

@main struct BrowserPointingWindowChecks {
    static func record(_ id: CGWindowID, _ bounds: CGRect, process: pid_t = 42, onScreen: Bool = true, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: process),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowIsOnscreen as String: onScreen,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    @MainActor static func main() {
        let bounds = CGRect(x: 0, y: 32, width: 1728, height: 1085)
        let source = record(100, bounds)
        let popup = record(101, CGRect(x: 300, y: 200, width: 400, height: 250))
        let wrongApp = record(102, bounds, process: 77)
        let matched = BrowserPointingController.matchingWindow(processID: 42, expectedBounds: bounds, windows: [popup, wrongApp, source])
        require(matched?.id == 100, "A child popup must not replace the uniquely matching source window.")
        require(BrowserPointingController.matchingWindow(processID: 42, expectedBounds: bounds,
            windows: [source, record(103, bounds)]) == nil, "Ambiguous bounds must not claim precision.")
        require(BrowserPointingController.matchingWindow(processID: 42, expectedBounds: bounds,
            windows: [record(100, bounds, onScreen: false)]) == nil, "Offscreen windows must not be selected.")
        let identity = matched!
        require(BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [popup, source]), "Z-ordering a child popup must preserve the original native window ID.")
        require(BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [record(100, bounds.offsetBy(dx: 1, dy: -1))]), "Subpoint/native rounding within tolerance should remain valid.")
        require(!BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [record(103, bounds)]), "A replacement native window with identical bounds is a different source.")
        require(!BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 77,
            windows: [source]), "An actual foreground app switch must clear precision.")
        require(!BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [record(100, bounds, onScreen: false)]), "An offscreen/minimized source must clear precision.")
        require(!BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [record(100, bounds.offsetBy(dx: 40, dy: 0))]), "Source movement beyond tolerance must clear precision.")
        require(!BrowserPointingController.sourceWindowIsCurrent(identity, processID: 42, foregroundProcessID: 42,
            windows: [record(100, bounds, process: 77)]), "Window identity cannot move to a different process.")
        print("PASS: native pointer window identity survives child popups and rejects ambiguous, replaced, moved, offscreen or background sources")
    }
}
