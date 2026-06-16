import Foundation

enum PrivacyFilter {
    static func isDenied(snapshot: ScreenSnapshot, deniedAppNames: [String]) -> Bool {
        let candidates = [
            snapshot.appName,
            snapshot.windowTitle ?? ""
        ].map { $0.lowercased() }

        return deniedAppNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .contains { deniedName in
                candidates.contains { $0.contains(deniedName) }
            }
    }
}
