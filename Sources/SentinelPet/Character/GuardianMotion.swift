import AppKit

struct GuardianIntervention: Identifiable {
    let id = UUID()
    let target: CGPoint
}

/// Target only the active app's current window. A delayed verdict must not send
/// the character toward an unrelated window after the user switches apps.
enum GuardianTarget {
    static func activeWindowCenter(expectedAppName: String? = nil) -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              expectedAppName == nil || app.localizedName == expectedAppName else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 100, rect.height > 100 else { continue }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGPoint(x: rect.midX, y: top - rect.midY)
        }
        return nil
    }
    static func demoTarget() -> CGPoint {
        activeWindowCenter() ?? CGPoint(x: NSScreen.main?.visibleFrame.midX ?? 500, y: NSScreen.main?.visibleFrame.midY ?? 400)
    }
}

/// Phase lengths are sent to Unreal with a shared wall-clock start time.
enum GuardianJumpTiming {
    static let anticipation = 0.36
    static let flight = 0.86
    static let landing = 0.32
    static func duration(for state: String) -> Double {
        switch state {
        case "notice": return anticipation
        case "jump", "return": return flight
        case "land": return landing
        default: return 1
        }
    }
    static func direction(from: CGPoint, to: CGPoint) -> Double {
        let dx = to.x - from.x
        return abs(dx) < 1 ? 0 : (dx > 0 ? 1 : -1)
    }
}

/// Screen anchors define rays in one fixed perspective camera. Unreal moves
/// the character between those rays in world space, toward/away from the camera.
struct GuardianDesktopScene {
    let viewport: CGRect
    let from: CGPoint
    let to: CGPoint
    let fromScale: Double
    let toScale: Double

    var command: [String: Any] {
        ["enabled": true, "width": viewport.width, "height": viewport.height,
         "fromX": from.x - viewport.minX, "fromY": from.y - viewport.minY,
         "toX": to.x - viewport.minX, "toY": to.y - viewport.minY,
         "fromScale": fromScale, "toScale": toScale, "homeSize": 220]
    }
    var reversed: GuardianDesktopScene {
        GuardianDesktopScene(viewport: viewport, from: to, to: from, fromScale: toScale, toScale: fromScale)
    }
}

/// Companion idle time, not keyboard/screen surveillance. Analysis and direct
/// interactions reset the clock; sleep never disables monitoring.
enum GuardianIdlePolicy {
    static func pose(after seconds: TimeInterval, protectionActive: Bool = false) -> String {
        if protectionActive { return "idle" }
        if seconds >= 55 { return "sleep" }
        if seconds >= 28 { return "drowsy" }
        return "idle"
    }
}
