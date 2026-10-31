import Foundation

@main struct WarningFeedbackSessionChecks {
    static func main() throws {
        let modelCaution = RiskVerdict(riskLevel: .medium, summary: "Model caution", guidance: "Check the destination", categories: ["uncertainty"])
        var session = WarningFeedbackSession(warningID: "visible-warning", source: "Chrome text", engine: "Local model", verdict: modelCaution)
        session.include(source: "Chrome text", engine: "Local model", verdict: modelCaution)
        assert(session.findings.count == 1, "Repeated delivery must not duplicate the finding.")
        let downloadWarning = RiskVerdict(riskLevel: .high, summary: "Static inspection concern", guidance: "Keep the file closed", categories: ["file"])
        session.include(source: "Download inspection", engine: "ClamAV", verdict: downloadWarning)
        assert(session.record(warningID: "stale-warning", summary: "Wrong warning", guidance: "") == nil,
            "A stale button must not label another warning.")
        let record = session.record(warningID: "visible-warning", summary: "Actual bounded card text", guidance: "Actual displayed guidance")!
        assert(record.summary == "Actual bounded card text" && record.guidance == "Actual displayed guidance")
        assert(record.riskLevel == .high && record.findings.count == 2)
        assert(record.findings[0].verdict.riskLevel == .medium && record.findings[0].engine == "Local model",
            "A merged static warning must not promote the model's original verdict in feedback.")
        assert(record.findings[1].verdict.riskLevel == .high && record.findings[1].engine == "ClamAV")
        assert(record.categories == ["file", "uncertainty"])
        assert(record.source == "Chrome text · Download inspection")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("warnings.json")
        let store = try WarningFeedbackStore(fileURL: file)
        let saved = try store.record(record)
        let duplicate = try store.record(record)
        assert(saved)
        assert(!duplicate, "A repeated click must be retained only once.")
        let reloaded = try WarningFeedbackStore(fileURL: file)
        assert(reloaded.records.count == 1 && reloaded.records[0].findings[0].verdict.riskLevel == .medium)

        // A separate newly displayed warning has no metadata from the old one.
        let next = WarningFeedbackSession(warningID: "new-warning", source: "Desktop text", engine: "Local model", verdict: modelCaution)
        assert(next.record(warningID: "visible-warning", summary: "", guidance: "") == nil)
        assert(next.findings.count == 1 && next.findings[0].source == "Desktop text")
        print("PASS: false-positive feedback binds the exact warning and displayed text, retains original merged verdicts, and persists once")
    }
}
