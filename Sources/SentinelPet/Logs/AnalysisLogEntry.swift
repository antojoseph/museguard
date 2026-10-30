import Foundation

enum AnalysisLogSource {
    #if MUSE_DEVELOPMENT
    case mock
    #endif
    case focusedWindow
    case screenshot
    case monitorScreenshot
    case browserText
    case browserVision

    var label: String {
        switch self {
        #if MUSE_DEVELOPMENT
        case .mock: return "Mock lab"
        #endif
        case .browserText: return "Chrome text"
        case .browserVision: return "Chrome visual check"
        case .focusedWindow:
            return "Focused window"
        case .screenshot:
            return "Screenshot"
        case .monitorScreenshot:
            return "Monitor screenshot"
        }
    }

    var systemImage: String {
        switch self {
        #if MUSE_DEVELOPMENT
        case .mock: return "testtube.2"
        #endif
        case .browserText: return "globe"
        case .browserVision: return "photo.on.rectangle"
        case .focusedWindow:
            return "text.viewfinder"
        case .screenshot:
            return "camera.viewfinder"
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
