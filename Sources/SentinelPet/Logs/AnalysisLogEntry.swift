import Foundation

enum AnalysisLogSource {
    #if MUSE_DEVELOPMENT
    case mock
    #endif
    case monitorScreenshot
    case monitorText
    case downloadInspection, secretPaste
    case browserText

    var label: String {
        switch self {
        #if MUSE_DEVELOPMENT
        case .mock: return "Mock lab"
        #endif
        case .downloadInspection: return "Download inspection"
        case .secretPaste: return "Secret paste protection"
        case .browserText: return "Chrome text"
        case .monitorText: return "Desktop text"
        case .monitorScreenshot:
            return "Monitor screenshot"
        }
    }

    var systemImage: String {
        switch self {
        #if MUSE_DEVELOPMENT
        case .mock: return "testtube.2"
        #endif
        case .downloadInspection: return "arrow.down.doc"
        case .secretPaste: return "key.horizontal"
        case .browserText: return "globe"
        case .monitorText: return "text.viewfinder"
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
