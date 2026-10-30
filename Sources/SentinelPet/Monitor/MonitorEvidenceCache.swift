import Foundation

/// Successful evidence and visual-attempt throttles are separate. A failed
/// attempt limits repeated image work without becoming an assessed receipt.
struct MonitorEvidenceCache {
    private struct Entry {
        var text: Int?
        var visualText: Int?
        var image: Int?
        var usedAt: Date
    }
    private var entries: [ScreenSourceIdentity: Entry] = [:]
    private var visualAttempts: [ScreenSourceIdentity: Date] = [:]
    let maximumSources: Int
    let visualInterval: TimeInterval

    init(maximumSources: Int = 16, visualInterval: TimeInterval = 60) {
        self.maximumSources = max(1, maximumSources)
        self.visualInterval = max(1, visualInterval)
    }
    mutating func removeAll() { entries.removeAll(); visualAttempts.removeAll() }
    func containsText(_ fingerprint: Int, source: ScreenSourceIdentity) -> Bool { entries[source]?.text == fingerprint }
    func visualCoolingDown(source: ScreenSourceIdentity, now: Date) -> Bool {
        guard let date = visualAttempts[source] else { return false }
        return now.timeIntervalSince(date) < visualInterval
    }
    mutating func beginVisualAttempt(source: ScreenSourceIdentity, now: Date) {
        visualAttempts[source] = now
        while visualAttempts.count > maximumSources, let oldest = visualAttempts.min(by: { $0.value < $1.value })?.key {
            visualAttempts.removeValue(forKey: oldest)
        }
    }
    func containsImage(_ fingerprint: Int, text: Int, source: ScreenSourceIdentity) -> Bool {
        entries[source]?.image == fingerprint && entries[source]?.visualText == text
    }
    mutating func rememberText(_ fingerprint: Int, source: ScreenSourceIdentity, now: Date) {
        var entry = entries[source] ?? Entry(usedAt: now)
        entry.text = fingerprint; entry.usedAt = now
        entries[source] = entry; trim()
    }
    mutating func rememberImage(_ fingerprint: Int, text: Int, source: ScreenSourceIdentity, now: Date) {
        var entry = entries[source] ?? Entry(usedAt: now)
        entry.image = fingerprint; entry.visualText = text; entry.text = text
        entry.usedAt = now
        entries[source] = entry; trim()
    }
    private mutating func trim() {
        while entries.count > maximumSources, let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
    static func textFingerprint(_ snapshot: ScreenSnapshot) -> Int {
        var hasher = Hasher()
        // Case can distinguish code, identifiers and account names.
        hasher.combine(snapshot.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        hasher.combine(snapshot.evidence.hasMeaningfulText)
        hasher.combine(snapshot.evidence.needsVisualContext)
        return hasher.finalize()
    }
    static func imageFingerprint(_ image: CapturedScreenshot) -> Int {
        var hasher = Hasher(); hasher.combine(image.dataURL)
        return hasher.finalize()
    }
}
