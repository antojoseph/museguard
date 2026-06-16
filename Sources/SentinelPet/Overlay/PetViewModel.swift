import SwiftUI

/// The pet's current emotional state, which drives its expression, glow, and
/// speech-bubble styling.
enum PetMood {
    case idle      // happily watching
    case scanning  // reading / analyzing the screen
    case alert     // detected something risky
}

/// Observable state shared between the pet sprite and its speech bubble.
@MainActor
final class PetViewModel: ObservableObject {
    @Published var mood: PetMood = .idle
    @Published var message: String?

    private var clearTask: Task<Void, Never>?

    /// Friendly first-launch greeting.
    func greet() {
        show(
            "Hi! I'm Claude, your security buddy. I'll keep an eye out for phishing, scams, and other sketchy stuff. 🛡️",
            mood: .idle,
            clearAfter: 9
        )
    }

    /// Display a message in the speech bubble, optionally auto-clearing it.
    func show(_ text: String, mood: PetMood = .idle, clearAfter seconds: Double? = nil) {
        clearTask?.cancel()
        self.message = text
        self.mood = mood

        guard let seconds else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.mood = .idle
        }
    }
}
