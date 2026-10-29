import Foundation
import SwiftUI

/// Exercises the real view model without opening a window or changing the
/// stored visibility/placement preferences.
@main struct GuardianAcknowledgmentChecks {
    @MainActor static func main() async throws {
        let model = PetViewModel()
        let warning = "This destination asks for your password and one-time code."

        // Let an ordinary message's timer start before a warning takes over.
        // That older timer must never clear the center intervention later.
        model.show("Earlier routine update", clearAfter: 0.08)
        try await Task.sleep(nanoseconds: 5_000_000)
        let details = GuardianWarningDetails(summary: warning, guidance: "Close this tab and use the official site.")
        assert(model.showAcknowledgment(id: "warning-one", text: warning, details: details))
        model.intervene(at: CGPoint(x: 864, y: 542))
        let interventionID = model.intervention!.id
        assert(model.acknowledgment?.id == "warning-one")
        assert(model.message == warning && model.mood == .alert)
        assert(model.warningDetails == details)
        assert(!model.bubbleIsDismissible)
        try await Task.sleep(nanoseconds: 120_000_000)
        assert(model.message == warning && model.intervention?.id == interventionID,
            "An old timer cannot send an unacknowledged guardian home.")

        // Routine, unknown and generic-close paths are weaker than an explicit
        // acknowledgement, including a close while the explanation is open.
        model.show("Everything looks ordinary", mood: .idle, clearAfter: 0.001)
        model.show("This check was inconclusive", mood: .scanning, clearAfter: 0.001)
        model.dismissBubble()
        assert(model.acknowledgment?.id == "warning-one")
        assert(model.message == warning && model.intervention?.id == interventionID)
        assert(!model.acknowledge(id: "different-warning"))
        assert(model.message == warning && model.intervention?.id == interventionID)

        model.openChat(seedText: "Why I flagged it")
        model.appendUserChat("What should I do?")
        model.setChatThinking(true)
        assert(model.isChatOpen && model.isChatThinking && model.chatMessages.count == 2)
        model.dismissBubble()
        assert(model.isChatOpen && model.isChatThinking && model.chatMessages.count == 2)
        assert(model.acknowledgment?.id == "warning-one" && model.intervention?.id == interventionID,
            "Opening or generically closing chat does not acknowledge a warning.")

        // Repeated transport deliveries cannot replace the message, chat or
        // identity of the warning awaiting the user's acknowledgement.
        assert(model.showAcknowledgment(id: "warning-one", text: "Duplicate delivery"))
        assert(!model.showAcknowledgment(id: "warning-two", text: "Different delivery"))
        assert(model.message == warning && model.chatMessages.count == 2 && model.isChatOpen)
        assert(model.warningDetails == details, "A repeated delivery must preserve the structured warning.")
        assert(model.intervention?.id == interventionID && model.acknowledgment?.id == "warning-one")
        try await Task.sleep(nanoseconds: 10_000_000)
        assert(model.message == warning && model.intervention?.id == interventionID,
            "Ignored routine messages must not leave a new clear timer behind.")

        assert(model.acknowledge(id: "warning-one"))
        assert(model.acknowledgment == nil && model.intervention == nil && model.message == nil)
        assert(model.warningDetails == nil)
        assert(model.mood == .idle && model.browserAction == nil)
        assert(!model.isChatOpen && !model.isChatThinking && model.chatMessages.isEmpty)
        assert(!model.acknowledge(id: "warning-one"), "An acknowledgement is consumed once.")

        assert(model.showAcknowledgment(id: "warning-two", text: "Next warning"))
        model.intervene(at: CGPoint(x: 500, y: 400))
        assert(!model.acknowledge(id: "warning-one"), "A stale button cannot clear the next warning.")
        assert(model.acknowledgment?.id == "warning-two" && model.intervention != nil)
        assert(model.acknowledge(id: "warning-two"))
        model.show("Routine updates resume after acknowledgement", clearAfter: 0.005)
        assert(model.message == "Routine updates resume after acknowledgement" && model.bubbleIsDismissible)
        try await Task.sleep(nanoseconds: 25_000_000)
        assert(model.message == nil && model.intervention == nil && model.mood == .idle)
        print("PASS: real guardian acknowledgement survives timers, routine updates, dismissal, chat and duplicate deliveries; only a matching explicit acknowledgement releases it")
    }
}
