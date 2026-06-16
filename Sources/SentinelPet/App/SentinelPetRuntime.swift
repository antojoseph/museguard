import Foundation

/// Shared app coordinator for menu actions, permissions, and pet feedback.
@MainActor
final class SentinelPetRuntime: ObservableObject {
    static let shared = SentinelPetRuntime()

    let petViewModel = PetViewModel()

    @Published private(set) var accessibilityTrusted: Bool

    private let screenReader = ScreenReader()

    private init() {
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
    }

    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityPermissionController.requestAccess()

        if accessibilityTrusted {
            petViewModel.show(
                "Accessibility access is enabled. I can read focused-window text now.",
                mood: .idle,
                clearAfter: 6
            )
        } else {
            petViewModel.show(
                "Please enable Sentinel Pet in Privacy & Security > Accessibility, then check again.",
                mood: .scanning,
                clearAfter: 10
            )
        }
    }

    func scanFocusedContext() {
        refreshAccessibilityStatus()

        guard accessibilityTrusted else {
            requestAccessibilityPermission()
            return
        }

        petViewModel.show("Reading the focused window...", mood: .scanning)

        do {
            let snapshot = try screenReader.readFocusedContext()
            petViewModel.show(
                previewMessage(for: snapshot),
                mood: .idle,
                clearAfter: 10
            )
        } catch {
            petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 8)
        }
    }

    private func previewMessage(for snapshot: ScreenSnapshot) -> String {
        let preview = snapshot.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(160)

        if preview.isEmpty {
            return "I can access \(snapshot.appName), but I did not find readable text there."
        }
        return "I can read \(snapshot.appName): \(preview)"
    }
}
