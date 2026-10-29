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

/// Desktop points and crop metadata use AppKit's bottom-left coordinates.
/// Keep these conversions independent of native windows for regression checks.
enum AvatarDesktopGeometry {
    static func viewport(screens: [CGRect]) -> CGRect {
        let union = screens.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? CGRect(x: 0,y: 0,width: 1440,height: 900) : union
    }
    static func bounded(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX-point.x,0,point.x-rect.maxX),max(rect.minY-point.y,0,point.y-rect.maxY))
        }
        guard let screen = screens.min(by: { distance($0)<distance($1) }) else { return point }
        return CGPoint(x:min(max(point.x,screen.minX+76),screen.maxX-76),y:min(max(point.y,screen.minY+86),screen.maxY-74))
    }
    static func homeRect(anchor: CGPoint, viewport: CGRect) -> CGRect {
        CGRect(x:anchor.x-viewport.minX-110,y:anchor.y-viewport.minY-110,width:220,height:220)
    }
    static func hasVisiblePixel(in image: CGImage, worldRect: CGRect, at point: CGPoint, threshold: UInt8 = 24) -> Bool {
        guard worldRect.width > 0, worldRect.height > 0, worldRect.contains(point),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let x = Int((point.x-worldRect.minX)/worldRect.width*CGFloat(image.width))
        let y = Int((worldRect.maxY-point.y)/worldRect.height*CGFloat(image.height))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return false }
        let index = y*image.bytesPerRow+x*4+3
        return index < CFDataGetLength(data) && bytes[index] > threshold
    }
    static func cropAnchor(_ rect: CGRect, viewport: CGRect) -> CGPoint {
        CGPoint(x:viewport.minX+rect.midX,y:viewport.minY+rect.midY)
    }
}
