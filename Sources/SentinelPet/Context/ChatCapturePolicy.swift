import Foundation

/// Route from trusted collection metadata and the user's own question. Page
/// text is evidence for the answer, never an instruction to capture an image.
enum ChatCapturePolicy {
    static func needsVisual(question: String, snapshot: ScreenSnapshot) -> Bool {
        if explicitlyRequestsVisualDetails(question) { return true }
        // Old callers supplied plain snapshots without role metadata. Preserve
        // useful text there, while measured AX toolbars remain insufficient.
        let evidence = snapshot.evidence.isMeasured ? snapshot.evidence : .visibleText(snapshot.text)
        return evidence.needsVisualContext
    }

    static func explicitlyRequestsVisualDetails(_ question: String) -> Bool {
        let words = String(question.prefix(2_000)).folding(options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let tokens = Set(words)
        let text = " " + words.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool {
            phrases.contains { text.contains(" " + $0 + " ") }
        }

        if has(["look closer", "look more closely", "take a closer look", "take a deeper look",
                "visually inspect", "inspect visually", "check visually", "look at the screenshot",
                "look at the image", "look at the picture", "what is in the screenshot",
                "what s in the screenshot", "what is in the image", "what s in the image",
                "what is in the picture", "what s in the picture"]) { return true }

        let references: Set<String> = ["this", "that", "these", "those"]
        func pointsAt(_ subjects: Set<String>, definiteArticle: Bool = false) -> Bool {
            for index in words.indices where subjects.contains(words[index]) {
                let preceding = words[max(0, index - 3)..<index]
                if preceding.contains(where: { references.contains($0) || (definiteArticle && $0 == "the") }) { return true }
            }
            return false
        }
        let explicitScreenReference = tokens.contains("here") ||
            has(["on screen", "on my screen", "on the screen", "current window", "current page", "visible window"])
        let visualSubjects: Set<String> = ["image", "images", "picture", "pictures", "photo", "photos",
            "screenshot", "screenshots", "chart", "charts", "graph", "graphs", "diagram", "diagrams",
            "drawing", "drawings", "canvas", "map", "maps", "video", "frame", "frames", "layout",
            "alignment", "spacing", "color", "colors", "colour", "colours", "font", "fonts", "shape",
            "shapes", "blurry", "blurred", "pixelated", "cropped", "clipped", "overlap", "overlapping"]
        if pointsAt(visualSubjects) || (explicitScreenReference && !tokens.isDisjoint(with: visualSubjects)) { return true }

        // Definite references such as "Explain the chart" also concern the
        // visible artifact; a generic "What is a chart?" stays text-only.
        let artifacts: Set<String> = ["image", "picture", "photo", "screenshot", "chart", "graph", "diagram", "drawing", "canvas", "layout"]
        let describesArtifact = !tokens.isDisjoint(with: ["describe", "explain", "read", "interpret", "inspect", "compare",
            "analyze", "analyse", "summarize", "summarise", "showing", "depict", "depicts"])
        let asksObservation = !tokens.isDisjoint(with: ["what", "why", "how"]) &&
            !tokens.isDisjoint(with: ["show", "shows", "saying", "says", "mean", "means", "wrong", "blurry", "clipped"])
        if pointsAt(artifacts, definiteArticle: true) && (describesArtifact || asksObservation) {
            return true
        }

        let interfaceObjects: Set<String> = ["button", "buttons", "icon", "icons", "dialog", "popup",
            "avatar", "badge", "cap", "bed", "interface", "window", "screen"]
        let appearance = !tokens.isDisjoint(with: ["looks", "appearance", "visually", "compare", "different",
            "color", "colors", "colour", "colours", "font", "fonts", "shape", "shapes", "alignment", "spacing",
            "red", "blue", "green", "yellow", "black", "white", "pink", "purple", "orange", "teal"]) ||
            has(["cut off", "hard to see", "can t see", "can t i see", "cannot see", "can i not see",
                 "not visible", "look right", "look wrong"])
        return appearance && !tokens.isDisjoint(with: interfaceObjects) &&
            (explicitScreenReference || pointsAt(interfaceObjects, definiteArticle: true))
    }
}
