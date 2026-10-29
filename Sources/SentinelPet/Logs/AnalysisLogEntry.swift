import Foundation

enum AnalysisLogSource {
    case mock
    case focusedWindow
    case screenshot
    case screenshotVerification
    case monitor
    case monitorScreenshot
    case browserText
    case browserVision

    var label: String {
        switch self {
        case .mock: return "Mock lab"
        case .browserText: return "Chrome text"
        case .browserVision: return "Chrome visual check"
        case .focusedWindow:
            return "Focused window"
        case .screenshot:
            return "Screenshot"
        case .screenshotVerification:
            return "High-detail verification"
        case .monitor:
            return "Monitor"
        case .monitorScreenshot:
            return "Monitor screenshot"
        }
    }

    var systemImage: String {
        switch self {
        case .mock: return "testtube.2"
        case .browserText: return "globe"
        case .browserVision: return "photo.on.rectangle"
        case .focusedWindow:
            return "text.viewfinder"
        case .screenshot:
            return "camera.viewfinder"
        case .screenshotVerification:
            return "checkmark.seal"
        case .monitor:
            return "eye"
        case .monitorScreenshot:
            return "eye.circle"
        }
    }
}

struct AnalysisLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let source: AnalysisLogSource
    let appName: String
    let windowTitle: String?
    let model: String
    let includesScreenshot: Bool
    let verdict: RiskVerdict?
    let errorMessage: String?
}
