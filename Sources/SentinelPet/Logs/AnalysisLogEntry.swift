import Foundation

enum AnalysisLogSource {
    case focusedWindow
    case screenshot
    case screenshotVerification
    case monitor

    var label: String {
        switch self {
        case .focusedWindow:
            return "Focused window"
        case .screenshot:
            return "Screenshot"
        case .screenshotVerification:
            return "High-detail verification"
        case .monitor:
            return "Monitor"
        }
    }

    var systemImage: String {
        switch self {
        case .focusedWindow:
            return "text.viewfinder"
        case .screenshot:
            return "camera.viewfinder"
        case .screenshotVerification:
            return "checkmark.seal"
        case .monitor:
            return "eye"
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
