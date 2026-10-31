import Foundation

enum PredictionDebugSourceKind: String {
    case browser
    case desktopText = "desktop_text"
    case desktopVisual = "desktop_visual"
}

enum PredictionDebugPhase: String {
    case waiting, checking, completed, unavailable, paused, stale, stopped
}

/// Display-only data. Opaque source identities, request IDs, page evidence,
/// URLs and screenshots are deliberately absent from this published value.
struct PredictionDebugSnapshot: Equatable {
    let phase: PredictionDebugPhase
    let kind: PredictionDebugSourceKind?
    let heading: String
    let riskLevel: RiskLevel?
    let summary: String?
    let timestamp: Date?
    var statusDetail: String? = nil

    static let initial = PredictionDebugSnapshot(phase: .waiting, kind: nil, heading: "No active source",
        riskLevel: nil, summary: nil, timestamp: nil)
}

/// In-memory source/request correlation for the currently watched context.
/// Callers supply an opaque key that changes with document/content identity;
/// neither a redacted URL nor the globally last assessment is a valid key.
struct PredictionDebugState {
    static let maximumHeadingBytes = 240
    static let maximumSummaryBytes = 600

    private struct Source {
        let key: String
        let kind: PredictionDebugSourceKind
        let heading: String
        let selectedAt: Date
    }
    private struct Entry {
        let requestID: String
        let generation: UInt64
        var phase: PredictionDebugPhase
        var timestamp: Date
        var riskLevel: RiskLevel?
        var summary: String?
        var sequence: UInt64
        var statusDetail: String? = nil
    }
    private var current: Source?
    private var entries: [String: Entry] = [:]
    private var seenRequests: [String: UInt64] = [:]
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var paused = false
    private var stopped = false
    private var statusChangedAt: Date?
    private let freshness: TimeInterval
    private let checkingTimeout: TimeInterval
    private let maxCachedSources: Int
    private let sanitizeSummary: (String) -> String?

    init(freshness: TimeInterval = 300, checkingTimeout: TimeInterval = 35, maxCachedSources: Int = 32,
         sanitizeSummary: @escaping (String) -> String? = { $0 }) {
        self.freshness = freshness.isFinite && freshness > 0 ? freshness : 300
        self.checkingTimeout = checkingTimeout.isFinite && checkingTimeout > 0 ? min(40, checkingTimeout) : 35
        self.maxCachedSources = min(128, max(1, maxCachedSources))
        self.sanitizeSummary = sanitizeSummary
    }

    var cachedSourceCount: Int { entries.count }

    mutating func setCurrentSource(key: String, kind: PredictionDebugSourceKind, heading: String, now: Date = Date()) {
        guard Self.validIdentity(key), Self.validDate(now) else { clearCurrentSource(now: now); return }
        if current?.key == key, current?.kind != kind {
            // Text and visual jobs for the same window are separate evidence
            // paths. Do not relabel a text verdict as a visual result.
            entries.removeValue(forKey: key)
        }
        let selected = current?.key == key && current?.kind == kind ? current!.selectedAt : now
        current = Source(key: key, kind: kind, heading: Self.displayText(heading, bytes: Self.maximumHeadingBytes), selectedAt: selected)
    }

    mutating func clearCurrentSource(now: Date = Date()) {
        current = nil
        if Self.validDate(now) { statusChangedAt = now }
    }

    @discardableResult
    mutating func begin(sourceKey: String, requestID: String, now: Date = Date()) -> Bool {
        guard !paused, !stopped, Self.validIdentity(sourceKey), Self.validIdentity(requestID), Self.validDate(now) else { return false }
        if let existing = entries[sourceKey], existing.requestID == requestID {
            // Polling the same coverage receipt must not restart its clock,
            // resurrect an expired result or hide a completed prediction.
            return existing.generation == generation && existing.phase == .checking
        }
        guard seenRequests[requestID] == nil else { return false }
        guard reserveEntry(for: sourceKey) else { return false }
        sequence &+= 1
        seenRequests[requestID] = sequence
        pruneSeenRequests()
        entries[sourceKey] = Entry(requestID: requestID, generation: generation, phase: .checking,
            timestamp: now, riskLevel: nil, summary: nil, sequence: sequence)
        return true
    }

    @discardableResult
    mutating func complete(sourceKey: String, requestID: String, verdict: RiskVerdict, now: Date = Date()) -> Bool {
        guard !paused, !stopped, Self.validDate(now), var entry = matching(sourceKey, requestID), entry.phase == .checking else { return false }
        entry.phase = .completed
        entry.timestamp = now
        entry.riskLevel = verdict.riskLevel
        entry.summary = sanitizeSummary(verdict.summary).map { Self.displayText($0, bytes: Self.maximumSummaryBytes) }
        sequence &+= 1; entry.sequence = sequence
        entries[sourceKey] = entry
        return true
    }

    @discardableResult
    mutating func fail(sourceKey: String, requestID: String, detail: String? = nil, now: Date = Date()) -> Bool {
        guard !paused, !stopped, Self.validDate(now), var entry = matching(sourceKey, requestID), entry.phase == .checking else { return false }
        entry.phase = .unavailable; entry.timestamp = now
        entry.riskLevel = nil; entry.summary = nil
        entry.statusDetail = detail.map { Self.displayText($0, bytes: Self.maximumSummaryBytes) }
        sequence &+= 1; entry.sequence = sequence
        entries[sourceKey] = entry
        return true
    }

    @discardableResult
    mutating func discard(sourceKey: String, requestID: String,
                         detail: String = "Activity changed during the check. Waiting for fresh context.", now: Date = Date()) -> Bool {
        guard !paused, !stopped, Self.validDate(now), var entry = matching(sourceKey, requestID), entry.phase == .checking else { return false }
        entry.phase = .waiting; entry.timestamp = now
        entry.riskLevel = nil; entry.summary = nil
        entry.statusDetail = Self.displayText(detail, bytes: Self.maximumSummaryBytes)
        entries[sourceKey] = entry
        return true
    }

    mutating func setPaused(_ value: Bool, now: Date = Date()) {
        guard value != paused else { return }
        paused = value; invalidate(now: now)
    }

    mutating func setStopped(_ value: Bool, now: Date = Date()) {
        guard value != stopped else { return }
        stopped = value; invalidate(now: now)
    }

    func snapshot(now: Date = Date()) -> PredictionDebugSnapshot {
        let heading = current?.heading.isEmpty == false ? current!.heading : PredictionDebugSnapshot.initial.heading
        func make(_ phase: PredictionDebugPhase, riskLevel: RiskLevel? = nil, summary: String? = nil, timestamp: Date? = nil, statusDetail: String? = nil) -> PredictionDebugSnapshot {
            PredictionDebugSnapshot(phase: phase, kind: current?.kind, heading: heading,
                riskLevel: riskLevel, summary: summary, timestamp: timestamp, statusDetail: statusDetail)
        }
        if paused { return make(.paused, timestamp: statusChangedAt) }
        if stopped { return make(.stopped, timestamp: statusChangedAt) }
        guard let current, let entry = entries[current.key], entry.generation == generation else {
            return make(.waiting, timestamp: current?.selectedAt)
        }
        if entry.phase == .unavailable { return make(.unavailable, timestamp: entry.timestamp, statusDetail: entry.statusDetail) }
        let age = now.timeIntervalSince(entry.timestamp)
        let limit = entry.phase == .checking ? checkingTimeout : freshness
        guard Self.validDate(now), age >= -1, age < limit else { return make(.stale, timestamp: entry.timestamp) }
        if entry.phase == .completed {
            return make(.completed, riskLevel: entry.riskLevel, summary: entry.summary, timestamp: entry.timestamp)
        }
        return make(entry.phase, timestamp: entry.timestamp, statusDetail: entry.statusDetail)
    }

    private func matching(_ sourceKey: String, _ requestID: String) -> Entry? {
        guard let entry = entries[sourceKey], entry.requestID == requestID, entry.generation == generation else { return nil }
        return entry
    }

    private mutating func invalidate(now: Date) {
        generation &+= 1
        entries.removeAll()
        statusChangedAt = Self.validDate(now) ? now : nil
        // Keep bounded request tombstones across pause/resume. An old coverage
        // receipt cannot be registered again as new work after monitoring stops.
    }

    private mutating func reserveEntry(for key: String) -> Bool {
        guard entries[key] == nil, entries.count >= maxCachedSources else { return true }
        guard let victim = entries.filter({ $0.key != current?.key }).min(by: { $0.value.sequence < $1.value.sequence })?.key else { return false }
        entries.removeValue(forKey: victim)
        return true
    }

    private mutating func pruneSeenRequests() {
        let limit = maxCachedSources * 4
        while seenRequests.count > limit {
            let active = Set(entries.values.map(\.requestID))
            guard let oldest = seenRequests.filter({ !active.contains($0.key) }).min(by: { $0.value < $1.value })?.key else { break }
            seenRequests.removeValue(forKey: oldest)
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite }

    private static func displayText(_ value: String, bytes: Int) -> String {
        let controls = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let range = NSRange(controls.startIndex..., in: controls)
        let pattern = #"(?i)\b(?:https?://|www\.)[^\s<>\"']+"#
        let withoutURLs = (try? NSRegularExpression(pattern: pattern))?
            .stringByReplacingMatches(in: controls, range: range, withTemplate: "[link]") ?? controls
        let text = withoutURLs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var prefix = Array(text.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            prefix.removeLast()
        }
        return ""
    }
}
