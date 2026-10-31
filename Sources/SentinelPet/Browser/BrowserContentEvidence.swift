import Foundation

/// Collector measurements describe the public content actually exposed to
/// Muse. Synthetic section headings and application chrome are not document
/// text, and a readable toolbar cannot stand in for an image-only document.
struct BrowserContentEvidence: Codable, Equatable {
    let version: Int
    let primaryTextCharacters: Int
    let visibleTextCharacters: Int
    let substantialVisuals: Int
    let requiresVisual: Bool
    let truncated: Bool
    let visualRevision: Int

    init(version: Int = 1, primaryTextCharacters: Int, visibleTextCharacters: Int,
         substantialVisuals: Int, requiresVisual: Bool, truncated: Bool, visualRevision: Int = 0) {
        self.version = version
        self.primaryTextCharacters = primaryTextCharacters
        self.visibleTextCharacters = visibleTextCharacters
        self.substantialVisuals = substantialVisuals
        self.requiresVisual = requiresVisual
        self.truncated = truncated
        self.visualRevision = visualRevision
    }

    enum CodingKeys: String, CodingKey {
        case version, truncated
        case primaryTextCharacters = "primary_text_characters"
        case visibleTextCharacters = "visible_text_characters"
        case substantialVisuals = "substantial_visuals"
        case requiresVisual = "requires_visual"
        case visualRevision = "visual_revision"
    }

    var hasMeaningfulPrimaryText: Bool { primaryTextCharacters >= 40 }
    var needsVisualContext: Bool { requiresVisual || !hasMeaningfulPrimaryText }

    func validated() throws -> BrowserContentEvidence {
        guard version == 1, (0...8_000).contains(primaryTextCharacters),
              (primaryTextCharacters...8_000).contains(visibleTextCharacters),
              (0...64).contains(substantialVisuals),
              (0...2_147_483_647).contains(visualRevision) else { throw ValidationError.invalid }
        return self
    }

    enum ValidationError: Error { case invalid }
}

/// The paired extension creates this lease only for the exact snapshot it
/// checked. A pending model job remains distinct from a successful result.
/// This correlation metadata never enters a model prompt or activity log.
struct BrowserCoverageProof: Codable, Equatable {
    let state: String
    let assessmentID: String
    let checkedAt: Int64
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case state
        case assessmentID = "assessment_id"
        case checkedAt = "checked_at"
        case expiresAt = "expires_at"
    }

    private var maximumLease: Int64 { state == "checking" ? 35_000 : 300_000 }

    func validated() throws -> BrowserCoverageProof {
        guard ["checking", "completed"].contains(state), !assessmentID.isEmpty,
              assessmentID.utf8.count <= 128,
              !assessmentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              checkedAt > 0, expiresAt > checkedAt,
              expiresAt - checkedAt <= maximumLease else { throw ValidationError.invalid }
        return self
    }

    func isFresh(at now: Date) -> Bool {
        guard (try? validated()) != nil else { return false }
        let milliseconds = now.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0,
              milliseconds < Double(Int64.max) else { return false }
        let timestamp = Int64(milliseconds)
        return checkedAt <= min(Int64.max - 1_000, timestamp) + 1_000 && expiresAt > timestamp &&
            timestamp - checkedAt <= maximumLease
    }

    enum ValidationError: Error { case invalid }
}
