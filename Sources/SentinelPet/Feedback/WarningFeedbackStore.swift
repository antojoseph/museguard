import Foundation

enum WarningFeedbackDisposition: String, Codable {
    case falsePositive = "false_positive"
}

struct WarningFeedbackFinding: Codable {
    let source: String
    let engine: String
    let verdict: RiskVerdict

    init(source: String, engine: String, verdict: RiskVerdict) {
        self.source = source; self.engine = engine; self.verdict = verdict
    }

    enum CodingKeys: String, CodingKey { case source, engine, verdict }

    init(from decoder: Decoder) throws {
        try requireFeedbackKeys(decoder, allowed: ["source", "engine", "verdict"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        engine = try values.decode(String.self, forKey: .engine)
        let nested = try values.superDecoder(forKey: .verdict)
        try requireFeedbackKeys(nested, allowed: ["risk_level", "summary", "guidance", "categories"])
        verdict = try RiskVerdict(from: nested)
    }
}

/// The displayed explanation is retained verbatim within storage limits. It
/// can include model quotations; this is not a copy of the underlying screen.
struct WarningFeedbackRecord: Codable {
    let warningID: String
    let timestamp: Date
    let disposition: WarningFeedbackDisposition
    let summary: String
    let guidance: String
    let riskLevel: RiskLevel?
    let source: String
    let engine: String
    let categories: [String]
    let findings: [WarningFeedbackFinding]

    init(warningID: String, timestamp: Date = Date(), disposition: WarningFeedbackDisposition = .falsePositive,
         summary: String, guidance: String, riskLevel: RiskLevel? = nil, source: String, engine: String,
         categories: [String] = [], findings: [WarningFeedbackFinding] = []) {
        self.warningID = warningID; self.timestamp = timestamp; self.disposition = disposition
        self.summary = summary; self.guidance = guidance; self.riskLevel = riskLevel
        self.source = source; self.engine = engine; self.categories = categories; self.findings = findings
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, disposition, summary, guidance, source, engine, categories, findings
        case warningID = "warning_id", riskLevel = "risk_level"
    }

    init(from decoder: Decoder) throws {
        try requireFeedbackKeys(decoder, allowed: ["warning_id", "timestamp", "disposition", "summary", "guidance",
            "risk_level", "source", "engine", "categories", "findings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        warningID = try values.decode(String.self, forKey: .warningID)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        disposition = try values.decode(WarningFeedbackDisposition.self, forKey: .disposition)
        summary = try values.decode(String.self, forKey: .summary)
        guidance = try values.decode(String.self, forKey: .guidance)
        riskLevel = try values.decodeIfPresent(RiskLevel.self, forKey: .riskLevel)
        source = try values.decode(String.self, forKey: .source)
        engine = try values.decode(String.self, forKey: .engine)
        categories = try values.decode([String].self, forKey: .categories)
        findings = try values.decodeIfPresent([WarningFeedbackFinding].self, forKey: .findings) ?? []
    }
}

/// Bounded local feedback, saved only after an explicit user action. Re-read
/// before each write so another instance or a corrupt file is never ignored.
final class WarningFeedbackStore {
    static let maximumRecords = 1_000
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumTextBytes = 8_000
    static let maximumMetadataBytes = 256
    static let maximumCategories = 16
    static let maximumCategoryBytes = 80
    static let maximumFindings = 12
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MuseGuard/Feedback/warnings.json")
    }

    private static let lock = NSLock()
    private let fileURL: URL
    private let manager = FileManager.default
    private(set) var records: [WarningFeedbackRecord] = []

    init(fileURL: URL = WarningFeedbackStore.defaultFileURL) throws {
        guard fileURL.isFileURL, !fileURL.lastPathComponent.isEmpty else { throw StoreError.invalidLocation }
        self.fileURL = fileURL.standardizedFileURL
        Self.lock.lock(); defer { Self.lock.unlock() }
        try prepareDirectory()
        let loaded = try readRecords()
        if try attributesIfPresent(self.fileURL) != nil {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
        }
        records = loaded
    }

    func contains(warningID: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return records.contains { $0.warningID == warningID }
    }

    /// False means this retained warning ID was already recorded. Failed
    /// writes throw and never change the existing file or the cached records.
    @discardableResult
    func record(_ value: WarningFeedbackRecord) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let normalized = try Self.normalized(value)
        try prepareDirectory()
        let current = try readRecords()
        if current.contains(where: { $0.warningID == normalized.warningID }) {
            records = current
            return false
        }
        var retained = Array((current + [normalized]).suffix(Self.maximumRecords))
        let encoder = Self.encoder()
        var chunks = try retained.map { try encoder.encode($0) }
        var bytes = chunks.reduce(2) { $0 + $1.count } + max(0, chunks.count - 1)
        while bytes > Self.maximumFileBytes && chunks.count > 1 {
            bytes -= chunks.removeFirst().count + 1
            retained.removeFirst()
        }
        guard bytes <= Self.maximumFileBytes else { throw StoreError.tooLarge }
        var data = Data("[".utf8)
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { data.append(0x2c) }
            data.append(chunk)
        }
        data.append(0x5d)
        try atomicWrite(data)
        records = retained
        return true
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        if let attributes = try attributesIfPresent(directory) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.invalidLocation }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try manager.attributesOfItem(atPath: url.path) }
        catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) { return nil }
            throw error
        }
    }

    private func readRecords() throws -> [WarningFeedbackRecord] {
        guard let attributes = try attributesIfPresent(fileURL) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.invalidLocation }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(Self.maximumFileBytes) else { throw StoreError.tooLarge }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumFileBytes {
            let chunk = try handle.read(upToCount: min(65_536, Self.maximumFileBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumFileBytes else { throw StoreError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode([WarningFeedbackRecord].self, from: data)
        guard decoded.count <= Self.maximumRecords, Set(decoded.map(\.warningID)).count == decoded.count else { throw StoreError.corrupt }
        for value in decoded { try Self.validateStored(value) }
        return decoded
    }

    private func atomicWrite(_ data: Data) throws {
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw StoreError.writeFailed }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if try attributesIfPresent(fileURL) != nil {
            _ = try manager.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: temporary, to: fileURL)
        }
    }

    private static func capped(_ text: String, bytes: Int) -> String {
        var prefix = Array(text.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
        }
        return ""
    }

    private static func cappedCategories(_ values: [String]) -> [String] {
        values.prefix(maximumCategories).map { capped($0, bytes: maximumCategoryBytes) }
    }

    private static func normalized(_ value: WarningFeedbackRecord) throws -> WarningFeedbackRecord {
        try validateIdentity(value)
        let findings = value.findings.prefix(maximumFindings).map { finding in
            WarningFeedbackFinding(source: capped(finding.source, bytes: maximumMetadataBytes),
                engine: capped(finding.engine, bytes: maximumMetadataBytes),
                verdict: RiskVerdict(riskLevel: finding.verdict.riskLevel,
                    summary: capped(finding.verdict.summary, bytes: maximumTextBytes),
                    guidance: capped(finding.verdict.guidance, bytes: maximumTextBytes), categories: cappedCategories(finding.verdict.categories)))
        }
        return WarningFeedbackRecord(warningID: value.warningID, timestamp: value.timestamp, disposition: value.disposition,
            summary: capped(value.summary, bytes: maximumTextBytes), guidance: capped(value.guidance, bytes: maximumTextBytes),
            riskLevel: value.riskLevel, source: capped(value.source, bytes: maximumMetadataBytes),
            engine: capped(value.engine, bytes: maximumMetadataBytes), categories: cappedCategories(value.categories), findings: Array(findings))
    }

    private static func validateIdentity(_ value: WarningFeedbackRecord) throws {
        guard !value.warningID.isEmpty, value.warningID.utf8.count <= maximumMetadataBytes,
              !value.warningID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.timestamp.timeIntervalSince1970.isFinite else { throw StoreError.corrupt }
    }

    private static func validateStored(_ value: WarningFeedbackRecord) throws {
        try validateIdentity(value)
        func validText(_ summary: String, _ guidance: String, _ source: String, _ engine: String, _ categories: [String]) -> Bool {
            summary.utf8.count <= maximumTextBytes && guidance.utf8.count <= maximumTextBytes &&
            source.utf8.count <= maximumMetadataBytes && engine.utf8.count <= maximumMetadataBytes &&
            categories.count <= maximumCategories && categories.allSatisfy { $0.utf8.count <= maximumCategoryBytes }
        }
        guard value.findings.count <= maximumFindings,
              validText(value.summary, value.guidance, value.source, value.engine, value.categories),
              value.findings.allSatisfy({ validText($0.verdict.summary, $0.verdict.guidance, $0.source, $0.engine, $0.verdict.categories) }) else { throw StoreError.corrupt }
    }

    enum StoreError: LocalizedError {
        case invalidLocation, corrupt, tooLarge, writeFailed
        var errorDescription: String? {
            switch self {
            case .invalidLocation: return "The local feedback location is not a regular file and private directory."
            case .corrupt: return "The local feedback data is invalid. It was not overwritten."
            case .tooLarge: return "The local feedback data exceeds its storage limit. It was not overwritten."
            case .writeFailed: return "Muse could not write the local feedback."
            }
        }
    }
}

private struct FeedbackCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireFeedbackKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: FeedbackCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected local feedback field."))
    }
}
