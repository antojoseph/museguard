import CoreGraphics
import Foundation

enum ScreenCapturePermissionController {
    static var isTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
