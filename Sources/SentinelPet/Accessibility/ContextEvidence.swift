import Foundation

/// Quality describes what was actually exposed, rather than counting toolbar
/// labels as a readable document or assuming every web area is a picture.
struct ContextEvidence: Equatable {
    var semanticTextCharacters: Int
    var semanticTextElements: Int
    var visualElements: Int
    var controlElements: Int
    var truncated: Bool
    var isMeasured: Bool
    var requiresVisual: Bool

    init(semanticTextCharacters: Int = 0, semanticTextElements: Int = 0,
         visualElements: Int = 0, controlElements: Int = 0,
         truncated: Bool = false, isMeasured: Bool = true, requiresVisual: Bool = false) {
        self.semanticTextCharacters = max(0, semanticTextCharacters)
        self.semanticTextElements = max(0, semanticTextElements)
        self.visualElements = max(0, visualElements)
        self.controlElements = max(0, controlElements)
        self.truncated = truncated
        self.isMeasured = isMeasured
        self.requiresVisual = requiresVisual
    }

    static let unknown = ContextEvidence(isMeasured: false)

    static func visibleText(_ text: String) -> ContextEvidence {
        let text = normalizedText(text)
        return ContextEvidence(semanticTextCharacters: text.count,
            semanticTextElements: text.isEmpty ? 0 : 1)
    }

    var hasMeaningfulText: Bool {
        isMeasured && semanticTextElements > 0 &&
            (semanticTextCharacters >= 40 || (semanticTextElements >= 2 && semanticTextCharacters >= 24))
    }

    var needsVisualContext: Bool {
        requiresVisual || !hasMeaningfulText || (visualElements > 0 && semanticTextCharacters < 240 &&
            visualElements >= semanticTextElements)
    }

    /// Whitespace changes are irrelevant; case, numbers and punctuation are
    /// preserved because they can change the meaning of financial or code text.
    static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Source identity is local correlation data and never enters a model prompt.
struct ScreenSourceIdentity: Equatable, Hashable {
    let processID: Int32
    let bundleID: String?
    let windowID: UInt32?
    let windowTitle: String?
    let appName: String

    init(processID: Int32, bundleID: String? = nil, windowID: UInt32? = nil,
         windowTitle: String? = nil, appName: String = "Current app") {
        self.processID = processID; self.bundleID = bundleID
        self.windowID = windowID; self.windowTitle = windowTitle; self.appName = appName
    }

    static func captureWindowID(focusedTitle: String?, focusedBounds: CGRect? = nil,
        candidates: [ScreenWindowCandidate]) -> UInt32? {
        let candidates = candidates.filter { $0.id != 0 }
        let title = focusedTitle.flatMap { $0.isEmpty ? nil : $0 }
        if let focusedBounds, validWindowBounds(focusedBounds) {
            let bounded = candidates.filter { $0.bounds.map(validWindowBounds) == true }
            let matches = bounded.filter { candidate in
                guard let bounds = candidate.bounds else { return false }
                return abs(bounds.minX - focusedBounds.minX) <= 4 && abs(bounds.minY - focusedBounds.minY) <= 4 &&
                    abs(bounds.width - focusedBounds.width) <= 4 && abs(bounds.height - focusedBounds.height) <= 4
            }
            if matches.count == 1 { return matches[0].id }
            if matches.count > 1 {
                let titled = matches.filter { title != nil && $0.title == title }
                return titled.count == 1 ? titled[0].id : nil
            }
            // A different current geometry means the AX and CG observations
            // no longer describe the same window. Let a later read retry.
            if !bounded.isEmpty { return nil }
        }
        if let title {
            let matches = candidates.filter { $0.title == title }
            if matches.count == 1 { return matches[0].id }
            if matches.count > 1 { return nil }
        }
        guard candidates.count == 1 else { return nil }
        if let title, let candidateTitle = candidates[0].title, !candidateTitle.isEmpty, title != candidateTitle { return nil }
        return candidates[0].id
    }

    static func metadataInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }

    static func validWindowBounds(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width > 0 && bounds.height > 0
    }
}

struct ScreenWindowCandidate {
    let id: UInt32
    let title: String?
    let bounds: CGRect?

    init(id: UInt32, title: String?, bounds: CGRect? = nil) {
        self.id = id; self.title = title; self.bounds = bounds
    }
}

/// Shared by the real AX walk and fixture checks. The text budget includes line
/// separators and duplicate attributes do not inflate the semantic evidence.
struct AccessibilityEvidenceBuilder {
    private let maximumCharacters: Int
    private var pieces: [String] = []
    private var seenPieces = Set<String>()
    private var semanticPieces = Set<String>()
    private var characterCount = 0
    private(set) var evidence = ContextEvidence()

    init(maxCharacters: Int) { maximumCharacters = max(0, maxCharacters) }
    var isFull: Bool { characterCount >= maximumCharacters }
    var text: String { pieces.joined(separator: "\n") }

    mutating func visit(role: String, inControlRegion: Bool, substantialVisual: Bool) {
        if Self.isControl(role) || inControlRegion { evidence.controlElements += 1 }
        if substantialVisual && !inControlRegion { evidence.visualElements += 1 }
    }

    mutating func append(_ text: String?, role: String, inControlRegion: Bool) {
        guard let text else { return }
        let normalized = ContextEvidence.normalizedText(text)
        guard !normalized.isEmpty else { return }
        let semantic = !inControlRegion && Self.isSemantic(role)
        if seenPieces.contains(normalized) {
            if semantic, semanticPieces.insert(normalized).inserted {
                evidence.semanticTextCharacters += min(maximumCharacters, normalized.count)
                evidence.semanticTextElements += 1
            }
            return
        }
        let remaining = maximumCharacters - characterCount - (pieces.isEmpty ? 0 : 1)
        guard remaining > 0 else { evidence.truncated = true; return }
        let clipped = String(normalized.prefix(remaining))
        seenPieces.insert(normalized)
        characterCount += clipped.count + (pieces.isEmpty ? 0 : 1)
        pieces.append(clipped)
        if clipped.count < normalized.count { evidence.truncated = true }
        if semantic, semanticPieces.insert(normalized).inserted {
            evidence.semanticTextCharacters += clipped.count
            evidence.semanticTextElements += 1
        }
    }

    mutating func markTruncated() { evidence.truncated = true }

    static func isSemantic(_ role: String) -> Bool {
        ["AXStaticText", "AXTextArea", "AXTextEntryArea", "AXHeading", "AXParagraph"].contains(role)
    }

    static func isControl(_ role: String) -> Bool {
        ["AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSlider",
         "AXTextField", "AXComboBox", "AXTab", "AXMenuItem"].contains(role)
    }

    static func isControlRegion(_ role: String) -> Bool {
        ["AXToolbar", "AXMenuBar", "AXMenu", "AXTabGroup"].contains(role)
    }
}
