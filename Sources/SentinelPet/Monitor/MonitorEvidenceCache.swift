import Foundation
import CoreGraphics
import ImageIO

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

    init(maximumSources: Int = 16, visualInterval: TimeInterval = 15) {
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

    /// A clock digit, caret or JPEG noise must not discard every visual
    /// assessment. This is a conservative pixel tolerance, not a claim that
    /// changed pixels have been semantically classified. AX text is checked
    /// separately and must still match exactly before a result is delivered.
    static func visuallyStable(_ original: CapturedScreenshot, _ latest: CapturedScreenshot) -> Bool {
        if original.dataURL == latest.dataURL { return true }
        guard let a = visualSample(original), let b = visualSample(latest),
              a.width == b.width, a.height == b.height else { return false }
        let width = 96, height = 64
        var changed = 0, left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = abs(Int(a.bytes[offset]) - Int(b.bytes[offset]))
                let green = abs(Int(a.bytes[offset + 1]) - Int(b.bytes[offset + 1]))
                let blue = abs(Int(a.bytes[offset + 2]) - Int(b.bytes[offset + 2]))
                guard max(red, green, blue) > 24, red + green + blue > 36 else { continue }
                changed += 1; left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        if changed == 0 { return true }
        // At most 0.2% of the sampled pixels, localized within 4% of the
        // window. Larger or scattered scene/layout changes are obsolete.
        return changed <= 12 && (right - left + 1) * (bottom - top + 1) <= 256
    }

    private static func visualSample(_ image: CapturedScreenshot) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let comma = image.dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(image.dataURL[image.dataURL.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 96 * 64 * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 96, height: 64,
                bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 96, height: 64))
            return true
        }
        return rendered ? (cgImage.width, cgImage.height, bytes) : nil
    }
}
