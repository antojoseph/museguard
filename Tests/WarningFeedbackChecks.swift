import Foundation

@main struct WarningFeedbackChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String = "") { assert(condition, message) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("muse-feedback-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        func record(_ id: String, summary: String = "Displayed caution", findings: [WarningFeedbackFinding] = []) -> WarningFeedbackRecord {
            WarningFeedbackRecord(warningID: id, timestamp: Date(timeIntervalSince1970: 1_800_000_000.125),
                summary: summary, guidance: "Verify independently.", riskLevel: .medium,
                source: "Browser text", engine: "muse-glimmer", categories: ["model_judgment"], findings: findings)
        }
        func expectFailure(_ operation: () throws -> Void) {
            do { try operation(); fatalError("A feedback failure was reported as success") } catch {}
        }
        func permissions(_ url: URL) throws -> Int {
            (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        func encoded(_ records: [WarningFeedbackRecord]) throws -> Data {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            return try encoder.encode(records)
        }

        let url = root.appendingPathComponent("durability/warnings.json")
        let store = try WarningFeedbackStore(fileURL: url)
        check(store.records.isEmpty && !store.contains(warningID: "one"))
        let quote = "Displayed model quote: alice@example.test at https://private.example/path?token=quoted."
        let findings = [
            WarningFeedbackFinding(source: "Browser text", engine: "muse-glimmer",
                verdict: RiskVerdict(riskLevel: .medium, summary: quote, guidance: "Review it.", categories: ["model_judgment"])),
            WarningFeedbackFinding(source: "Secret paste", engine: "Local format detector",
                verdict: RiskVerdict(riskLevel: .high, summary: "A secret may have been pasted.", guidance: "Undo if unintended.", categories: ["private_key"]))
        ]
        check(try store.record(record("one", summary: quote, findings: findings)))
        check(try permissions(url.deletingLastPathComponent()) == 0o700)
        check(try permissions(url) == 0o600)
        let original = try Data(contentsOf: url)
        let restarted = try WarningFeedbackStore(fileURL: url)
        check(restarted.records.count == 1 && restarted.contains(warningID: "one"))
        check(restarted.records[0].summary == quote, "Displayed quotations must not be silently redacted.")
        check(restarted.records[0].timestamp == record("one").timestamp)
        check(restarted.records[0].disposition == .falsePositive)
        check(restarted.records[0].findings.map { $0.verdict.riskLevel } == [.medium, .high], "Merged findings retain individual severities and engines.")
        check(!(try restarted.record(record("one", summary: "Changed duplicate"))))
        check(try Data(contentsOf: url) == original, "A duplicate ID must retain the first saved record across restart.")
        check(try store.record(record("two")))
        check(try restarted.record(record("three")))
        check(try WarningFeedbackStore(fileURL: url).records.map(\.warningID) == ["one", "two", "three"], "Separate store instances re-read prior saves.")

        let wire = try JSONSerialization.jsonObject(with: original) as! [[String: Any]]
        check(Set(wire[0].keys) == Set(["warning_id", "timestamp", "disposition", "summary", "guidance", "risk_level", "source", "engine", "categories", "findings"]))
        check(wire[0]["disposition"] as? String == "false_positive")
        let findingWire = wire[0]["findings"] as! [[String: Any]]
        check(Set(findingWire[0].keys) == Set(["source", "engine", "verdict"]))
        check(Set((findingWire[0]["verdict"] as! [String: Any]).keys) == Set(["risk_level", "summary", "guidance", "categories"]))

        let capsURL = root.appendingPathComponent("caps/warnings.json")
        let caps = try WarningFeedbackStore(fileURL: capsURL)
        let longText = String(repeating: "🙂", count: 4_000)
        let longCategories = (0..<30).map { "category-\($0)-" + String(repeating: "x", count: 200) }
        let hugeFinding = WarningFeedbackFinding(source: String(repeating: "s", count: 400), engine: String(repeating: "e", count: 400),
            verdict: RiskVerdict(riskLevel: .medium, summary: longText, guidance: longText, categories: longCategories))
        let oversized = WarningFeedbackRecord(warningID: "caps", summary: longText, guidance: longText,
            source: String(repeating: "s", count: 400), engine: String(repeating: "e", count: 400),
            categories: longCategories, findings: Array(repeating: hugeFinding, count: 20))
        check(try caps.record(oversized))
        let bounded = try WarningFeedbackStore(fileURL: capsURL).records[0]
        check(bounded.summary.utf8.count == 8_000 && !bounded.summary.contains("�"))
        check(bounded.guidance.utf8.count <= 8_000 && bounded.source.utf8.count == 256 && bounded.engine.utf8.count == 256)
        check(bounded.categories.count == 16 && bounded.categories.allSatisfy { $0.utf8.count <= 80 })
        check(bounded.findings.count == 12 && bounded.findings.allSatisfy { $0.verdict.summary.utf8.count <= 8_000 && $0.verdict.categories.count <= 16 })
        let beforeInvalid = try Data(contentsOf: capsURL)
        expectFailure { _ = try caps.record(record(String(repeating: "x", count: 257))) }
        check(try Data(contentsOf: capsURL) == beforeInvalid)

        let retentionURL = root.appendingPathComponent("retention/warnings.json")
        _ = try WarningFeedbackStore(fileURL: retentionURL)
        let thousand = (0..<1_000).map { record("record-\($0)") }
        try encoded(thousand).write(to: retentionURL)
        let retention = try WarningFeedbackStore(fileURL: retentionURL)
        check(try retention.record(record("newest")))
        let retained = try WarningFeedbackStore(fileURL: retentionURL)
        check(retained.records.count == 1_000 && retained.records.first?.warningID == "record-1" && retained.records.last?.warningID == "newest")

        // Keep the total encoded file bounded even when each merged warning
        // contains twelve individually bounded, long explanations.
        let volumeURL = root.appendingPathComponent("volume/warnings.json")
        _ = try WarningFeedbackStore(fileURL: volumeURL)
        // Seed valid bounded records using the real normalization path.
        let oneLarge = try WarningFeedbackStore(fileURL: capsURL).records[0]
        let initialVolume = (0..<30).map { index in
            WarningFeedbackRecord(warningID: "large-\(index)", summary: oneLarge.summary, guidance: oneLarge.guidance,
                source: oneLarge.source, engine: oneLarge.engine, categories: oneLarge.categories, findings: oneLarge.findings)
        }
        try encoded(initialVolume).write(to: volumeURL)
        let volume = try WarningFeedbackStore(fileURL: volumeURL)
        for index in 30..<50 {
            let value = WarningFeedbackRecord(warningID: "large-\(index)", summary: oneLarge.summary, guidance: oneLarge.guidance,
                source: oneLarge.source, engine: oneLarge.engine, categories: oneLarge.categories, findings: oneLarge.findings)
            check(try volume.record(value))
        }
        check(try Data(contentsOf: volumeURL).count <= 8 * 1_024 * 1_024)
        check(volume.records.count < 50 && volume.records.last?.warningID == "large-49")

        // Corruption after initialization must also fail instead of silently
        // replacing the unreadable file with the in-memory snapshot.
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: url)
        let cachedCount = restarted.records.count
        expectFailure { _ = try restarted.record(record("must-not-save")) }
        check(try Data(contentsOf: url) == corrupt && restarted.records.count == cachedCount)
        expectFailure { _ = try WarningFeedbackStore(fileURL: url) }
        var unexpected = wire
        unexpected[0]["raw_page"] = "PRIVATE_SCREEN_CONTENT"
        let unknownField = try JSONSerialization.data(withJSONObject: unexpected)
        try unknownField.write(to: url)
        expectFailure { _ = try restarted.record(record("must-not-save")) }
        check(try Data(contentsOf: url) == unknownField)
        try encoded([record("duplicate"), record("duplicate")]).write(to: url)
        let duplicateData = try Data(contentsOf: url)
        expectFailure { _ = try WarningFeedbackStore(fileURL: url) }
        check(try Data(contentsOf: url) == duplicateData)

        // A genuine replacement failure leaves the prior valid file and the
        // in-memory snapshot intact. The immutable flag is restored on exit.
        let lockedURL = root.appendingPathComponent("locked/warnings.json")
        let locked = try WarningFeedbackStore(fileURL: lockedURL)
        check(try locked.record(record("original")))
        let lockedData = try Data(contentsOf: lockedURL)
        try manager.setAttributes([.immutable: true], ofItemAtPath: lockedURL.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: lockedURL.path) }
        expectFailure { _ = try locked.record(record("failed-write")) }
        check(try Data(contentsOf: lockedURL) == lockedData && locked.records.map(\.warningID) == ["original"])
        try manager.setAttributes([.immutable: false], ofItemAtPath: lockedURL.path)
        check(try manager.contentsOfDirectory(atPath: lockedURL.deletingLastPathComponent().path) == ["warnings.json"], "Failed writes leave no temporary feedback files.")

        let obstacle = root.appendingPathComponent("directory-obstacle")
        let obstacleData = Data("leave this existing file unchanged".utf8)
        try obstacleData.write(to: obstacle)
        expectFailure { _ = try WarningFeedbackStore(fileURL: obstacle.appendingPathComponent("warnings.json")) }
        check(try Data(contentsOf: obstacle) == obstacleData)
        print("PASS: feedback durability, duplicate IDs, per-finding severity, private schema/permissions, UTF-8/record/file caps, corrupt reads and atomic-write failure preservation")
    }
}
