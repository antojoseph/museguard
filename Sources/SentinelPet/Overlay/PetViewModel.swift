import SwiftUI

/// The pet's current emotional state, which drives its expression, glow, and
/// speech-bubble styling.
enum PetMood {
    case idle      // happily watching
    case scanning  // reading / analyzing the screen
    case alert     // detected something risky
}

enum PetChatRole: Equatable {
    case user
    case assistant
}

struct PetChatMessage: Identifiable {
    let id = UUID()
    let role: PetChatRole
    let text: String
}

/// Observable state shared between the pet sprite and its speech bubble.
@MainActor
final class PetViewModel: ObservableObject {
    @Published var mood: PetMood = .idle
    @Published var message: String?
    @Published private var idleThought: String?
    @Published var isChatOpen = false
    @Published var isChatThinking = false
    @Published var chatMessages: [PetChatMessage] = []

    private var clearTask: Task<Void, Never>?
    private var idleThoughtTask: Task<Void, Never>?

    var bubbleText: String? {
        message ?? idleThought
    }

    var bubbleMood: PetMood {
        message == nil ? .idle : mood
    }

    var bubbleIsDismissible: Bool {
        message != nil
    }

    /// Friendly first-launch greeting.
    func greet() {
        startIdleThoughts()
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
        isChatOpen = false
        isChatThinking = false
        chatMessages.removeAll()

        guard let seconds else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.mood = .idle
        }
    }

    func openChat() {
        clearTask?.cancel()

        if chatMessages.isEmpty, let bubbleText {
            chatMessages.append(
                PetChatMessage(
                    role: .assistant,
                    text: bubbleText
                        .replacingOccurrences(of: "\nWhy? Tap to learn more.", with: "")
                        .replacingOccurrences(of: "\nTap to ask me why.", with: "")
                )
            )
        }

        isChatOpen = true
    }

    func dismissBubble() {
        clearTask?.cancel()
        message = nil
        mood = .idle
        isChatOpen = false
        isChatThinking = false
        chatMessages.removeAll()
    }

    func appendUserChat(_ text: String) {
        chatMessages.append(PetChatMessage(role: .user, text: text))
    }

    func appendAssistantChat(_ text: String) {
        chatMessages.append(PetChatMessage(role: .assistant, text: text))
    }

    func setChatThinking(_ isThinking: Bool) {
        isChatThinking = isThinking
    }

    private func startIdleThoughts() {
        guard idleThoughtTask == nil else { return }

        let thoughts = [
            "Thinking about suspicious links...",
            "Watching for sketchy vibes.",
            "Tiny shield, big opinions.",
            "Wondering if that login page is real.",
            "Sniffing for scammy urgency.",
            "Keeping an eye on the fine print."
        ]
        idleThought = thoughts[0]

        idleThoughtTask = Task { [weak self] in
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 18 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.idleThought = thoughts[index % thoughts.count]
                index += 1
            }
        }
    }

    deinit {
        clearTask?.cancel()
        idleThoughtTask?.cancel()
    }
}
