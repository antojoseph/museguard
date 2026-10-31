import Foundation

/// Metadata belongs to the pinned warning, independently of later chat or
/// background checks. One dismissal labels the entire displayed warning.
struct WarningFeedbackSession {
    let warningID: String
    private(set) var findings: [WarningFeedbackFinding] = []

    init(warningID: String, source: String, engine: String, verdict: RiskVerdict) {
        self.warningID = warningID
        include(source: source, engine: engine, verdict: verdict)
    }

    mutating func include(source: String, engine: String, verdict: RiskVerdict) {
        guard !findings.contains(where: {
            $0.source == source && $0.engine == engine && $0.verdict.riskLevel == verdict.riskLevel &&
            $0.verdict.summary == verdict.summary && $0.verdict.guidance == verdict.guidance &&
            $0.verdict.categories == verdict.categories
        }) else { return }
        findings.append(WarningFeedbackFinding(source: source, engine: engine, verdict: verdict))
        findings = Array(findings.suffix(12))
    }

    func record(warningID: String, summary: String, guidance: String) -> WarningFeedbackRecord? {
        guard self.warningID == warningID else { return nil }
        return WarningFeedbackRecord(warningID: warningID, summary: summary, guidance: guidance,
            riskLevel: findings.contains { $0.verdict.riskLevel == .high } ? .high : findings.last?.verdict.riskLevel,
            source: Set(findings.map(\.source)).sorted().joined(separator: " · "),
            engine: Set(findings.map(\.engine)).sorted().joined(separator: " · "),
            categories: Array(Set(findings.flatMap { $0.verdict.categories })).sorted(), findings: findings)
    }
}
