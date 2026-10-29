import AppKit

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

/// The avatar’s idle clock selects drowsy and sleeping animation states.
enum GuardianIdlePolicy {
    static func pose(after seconds: TimeInterval) -> String {
        if seconds >= 55 { return "sleep" }
        if seconds >= 28 { return "drowsy" }
        return "idle"
    }
}
