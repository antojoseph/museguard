import Foundation

enum BuildConfiguration {
    static var visualTestingEnabled: Bool {
        #if MUSE_DEVELOPMENT
        return ProcessInfo.processInfo.arguments.contains("--visual-test")
        #else
        return false
        #endif
    }
}
