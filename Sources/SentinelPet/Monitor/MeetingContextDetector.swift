import Foundation

enum MeetingContextDetector {
    private static let appKeywords = [
        "google chrome",
        "safari",
        "zoom",
        "microsoft teams",
        "teams",
        "google meet",
        "facetime",
        "webex",
        "slack",
        "discord"
    ]

    private static let strongKeywords = [
        "google meet",
        "meet.google.com",
        "zoom meeting",
        "microsoft teams",
        "teams meeting",
        "facetime",
        "webex",
        "slack huddle",
        "video call",
        "screen sharing"
    ]

    private static let meetingSignals = [
        "join meeting",
        "leave call",
        "mute",
        "unmute",
        "camera",
        "microphone",
        "participants",
        "presenting",
        "presentation",
        "share screen",
        "waiting room",
        "meeting code",
        "call ended"
    ]

    static func isMeetingContext(_ snapshot: ScreenSnapshot) -> Bool {
        let appAndWindow = normalized([snapshot.appName, snapshot.windowTitle].compactMap { $0 })
        let allText = normalized([snapshot.appName, snapshot.windowTitle, snapshot.text].compactMap { $0 })

        if strongKeywords.contains(where: allText.contains) {
            return true
        }

        let appLooksRelevant = appKeywords.contains { appAndWindow.contains($0) }
        let signalCount = meetingSignals.filter { allText.contains($0) }.count

        return appLooksRelevant && signalCount >= 2
    }

    private static func normalized(_ pieces: [String]) -> String {
        pieces
            .joined(separator: " ")
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
