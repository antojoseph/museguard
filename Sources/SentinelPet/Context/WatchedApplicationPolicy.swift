import Foundation

/// Muse may retain the app behind its chat panel, but never behind Settings,
/// an open menu, or an unrelated application that the user has activated.
enum WatchedApplicationPolicy {
    static let chatWindowIdentifier = "muse.chat"

    static func processToWatch(frontmost: Int32?, ownProcess: Int32, chatOpen: Bool,
        keyWindowIdentifier: String?, lastExternal: Int32?, ignoredProcesses: Set<Int32> = [],
        menuTracking: Bool = false) -> Int32? {
        guard let frontmost else { return nil }
        if frontmost != ownProcess {
            return ignoredProcesses.contains(frontmost) ? nil : frontmost
        }
        guard chatOpen, !menuTracking, keyWindowIdentifier == chatWindowIdentifier,
              let lastExternal, lastExternal != ownProcess,
              !ignoredProcesses.contains(lastExternal) else { return nil }
        return lastExternal
    }
}
