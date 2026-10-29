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

/// A pending Chrome action that can be resolved only from Muse's native UI.
struct BrowserAvatarAction: Equatable {
    let assessmentID: String
    let canContinue: Bool
}

/// A warning remains pinned until this exact warning is acknowledged.
struct GuardianAcknowledgment: Equatable {
    let id: String
}

/// Keep the model's finding and guidance distinct in the warning card.
struct GuardianWarningDetails: Equatable {
    let summary: String
    let guidance: String
}

/// Observable state shared between the pet sprite and its speech bubble.
@MainActor
final class PetViewModel: ObservableObject {
    @Published var isAvatarHidden = UserDefaults.standard.bool(forKey: "museAvatarHidden") {
        didSet { UserDefaults.standard.set(isAvatarHidden, forKey: "museAvatarHidden") }
    }
    @Published var automaticallyPositions = (UserDefaults.standard.object(forKey: "museAutoPlacement") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(automaticallyPositions, forKey:"museAutoPlacement") }
    }
    @Published var intervention: GuardianIntervention?
    @Published var mood: PetMood = .idle
    @Published var message: String?
    @Published var isChatOpen = false
    @Published var isChatThinking = false
    @Published var chatMessages: [PetChatMessage] = []
    @Published var chatContextLabel: String?
    @Published var browserAction: BrowserAvatarAction?
    @Published private(set) var acknowledgment: GuardianAcknowledgment?
    @Published private(set) var warningDetails: GuardianWarningDetails?

    private var clearTask: Task<Void, Never>?

    var bubbleText: String? {
        message
    }

    var bubbleMood: PetMood {
        message == nil ? .idle : mood
    }

    var bubbleIsDismissible: Bool {
        message != nil && acknowledgment == nil
    }

    /// Friendly first-launch greeting.
    func greet() {
        show(
            "Hi, I’m Muse Guard. Your little extra pair of eyes. 🛡️",
            mood: .idle,
            clearAfter: 5
        )
    }

    /// Display a message in the speech bubble, optionally auto-clearing it.
    func show(_ text: String, mood: PetMood = .idle, clearAfter seconds: Double? = nil) {
        guard acknowledgment == nil else { return }
        clearTask?.cancel()
        browserAction = nil
        self.message = text
        self.mood = mood
        isChatOpen = false
        isChatThinking = false
        chatMessages.removeAll()
        chatContextLabel = nil

        guard let seconds else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self?.acknowledgment == nil else { return }
            self?.intervention = nil
            self?.browserAction = nil
            self?.message = nil
            self?.mood = .idle
        }
    }

    /// A new routine result, timer or dismissal cannot replace a pinned warning.
    @discardableResult
    func showAcknowledgment(id: String, text: String, details: GuardianWarningDetails? = nil) -> Bool {
        if let acknowledgment { return acknowledgment.id == id }
        clearTask?.cancel(); clearTask = nil
        acknowledgment = GuardianAcknowledgment(id: id)
        warningDetails = details
        browserAction = nil
        message = text
        mood = .alert
        isChatOpen = false
        isChatThinking = false
        chatMessages.removeAll()
        chatContextLabel = nil
        return true
    }

    /// Only an explicit, matching Got it can release the warning and guardian.
    @discardableResult
    func acknowledge(id: String) -> Bool {
        guard acknowledgment?.id == id else { return false }
        acknowledgment = nil
        dismissBubble()
        return true
    }

    func openChat(seedText: String? = nil) {
        clearTask?.cancel()

        if chatMessages.isEmpty, let seedText {
            chatMessages.append(PetChatMessage(role: .assistant, text: seedText))
        } else if chatMessages.isEmpty, let bubbleText {
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
        guard acknowledgment == nil else { return }
        warningDetails = nil
        browserAction = nil
        intervention = nil
        clearTask?.cancel()
        message = nil
        mood = .idle
        isChatOpen = false
        isChatThinking = false
        chatMessages.removeAll()
        chatContextLabel = nil
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

    func intervene(at target: CGPoint) {
        intervention = GuardianIntervention(target: target)
    }

    deinit { clearTask?.cancel() }
}
