import Foundation
import Darwin

/// Reads only a bounded ZIP central directory. No extraction or payload code
/// execution occurs; ClamAV performs bounded payload scanning when available.
enum DownloadZipInspection {
    struct Result { var findings: [String] = []; var high = false; var limited = false }
    static func inspect(fd: Int32, size: Int64, limits: DownloadInspectionLimits) -> Result {
        var result = Result()
        func limited(_ code: String) -> Result { var value = result; value.findings.append(code); value.limited = true; return value }
        guard size >= 22 else { return limited("archive_invalid_directory") }
        let tailCount = Int(min(size, 65_557))
        guard let tail = read(fd: fd, offset: size - Int64(tailCount), count: tailCount) else { return limited("archive_unreadable") }
        var end: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, offset) == 0x06054b50, let comment = u16(tail, offset + 20), offset + 22 + Int(comment) == tail.count { end = offset; break }
        }
        guard let end, let disk = u16(tail, end + 4), let centralDisk = u16(tail, end + 6),
              let diskEntries = u16(tail, end + 8), let entries = u16(tail, end + 10),
              let centralSize = u32(tail, end + 12), let centralOffset = u32(tail, end + 16) else { return limited("archive_invalid_directory") }
        guard disk == 0, centralDisk == 0, diskEntries == entries else { return limited("archive_multivolume") }
        guard entries != 0xffff, centralSize != 0xffffffff, centralOffset != 0xffffffff else { return limited("archive_zip64_unassessed") }
        guard Int(entries) <= limits.maximumArchiveEntries, Int(centralSize) <= limits.maximumCentralDirectoryBytes else { return limited("archive_entry_limit") }
        let absoluteEnd = size - Int64(tailCount) + Int64(end)
        guard Int64(centralOffset) + Int64(centralSize) <= absoluteEnd,
              let central = read(fd: fd, offset: Int64(centralOffset), count: Int(centralSize)) else { return limited("archive_invalid_directory") }
        var offset = 0, expanded: Int64 = 0, seen = Set<String>()
        for _ in 0..<Int(entries) {
            guard offset + 46 <= central.count, u32(central, offset) == 0x02014b50,
                  let flags = u16(central, offset + 8), let compressed = u32(central, offset + 20),
                  let uncompressed = u32(central, offset + 24), let nameSize = u16(central, offset + 28),
                  let extra = u16(central, offset + 30), let comment = u16(central, offset + 32),
                  let attributes = u32(central, offset + 38), let localOffset = u32(central, offset + 42) else { return limited("archive_invalid_directory") }
            let next = offset + 46 + Int(nameSize) + Int(extra) + Int(comment)
            guard next <= central.count, nameSize > 0, nameSize <= 4096 else { return limited("archive_invalid_directory") }
            let bytes = central.subdata(in: offset + 46 ..< offset + 46 + Int(nameSize))
            guard let name = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { return limited("archive_invalid_filename") }
            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            if unsafePath(normalized) {
                result.findings.append("archive_path_traversal"); result.high = true
            }
            // Streaming extractors may use the local header rather than the
            // central name. Correlate both without extracting any bytes.
            if let local = read(fd: fd, offset: Int64(localOffset), count: 30), u32(local, 0) == 0x04034b50,
               let localNameSize = u16(local, 26), localNameSize > 0, localNameSize <= 4096,
               Int64(localOffset) + 30 + Int64(localNameSize) <= Int64(centralOffset),
               let localBytes = read(fd: fd, offset: Int64(localOffset) + 30, count: Int(localNameSize)),
               let localName = String(data: localBytes, encoding: .utf8) ?? String(data: localBytes, encoding: .isoLatin1) {
                if unsafePath(localName) { result.findings.append("archive_path_traversal"); result.high = true }
                if localName != name { result.findings.append("archive_filename_mismatch"); result.limited = true }
            } else { result.findings.append("archive_invalid_local_header"); result.limited = true }
            // Info-ZIP Unicode path metadata can override a superficially safe
            // legacy filename. Inspect it too instead of assuming the name.
            var extraOffset = offset + 46 + Int(nameSize)
            let extraEnd = extraOffset + Int(extra)
            while extraOffset < extraEnd {
                guard let tag = u16(central, extraOffset), let fieldSize = u16(central, extraOffset + 2),
                      extraOffset + 4 + Int(fieldSize) <= extraEnd else { return limited("archive_invalid_extra_metadata") }
                if tag == 0x7075 {
                    if fieldSize >= 5, central[extraOffset + 4] == 1,
                       let unicodeName = String(data: central.subdata(in: extraOffset + 9 ..< extraOffset + 4 + Int(fieldSize)), encoding: .utf8) {
                        if unsafePath(unicodeName) { result.findings.append("archive_path_traversal"); result.high = true }
                    } else { result.findings.append("archive_unicode_path_unassessed"); result.limited = true }
                }
                extraOffset += 4 + Int(fieldSize)
            }
            if !seen.insert(normalized).inserted { result.findings.append("archive_duplicate_names") }
            if flags & 1 != 0 { result.findings.append("archive_encrypted"); result.limited = true }
            if (attributes >> 16) & 0xf000 == 0xa000 { result.findings.append("archive_symbolic_link"); result.limited = true }
            expanded += Int64(uncompressed)
            if expanded > limits.maximumArchiveBytes || (uncompressed > 10 * 1_024 * 1_024 && Int64(uncompressed) > max(1, Int64(compressed)) * 1_000) {
                result.findings.append("archive_expansion_limit"); result.limited = true
            }
            let lower = normalized.lowercased()
            let ext = (lower as NSString).pathExtension
            if ["app", "command", "sh", "scpt", "pkg", "dmg", "exe", "msi", "scr", "bat", "ps1", "vbs", "js", "jar"].contains(ext) {
                result.findings.append("archive_executable_content")
                if [".pdf.", ".png.", ".jpg.", ".docx.", ".txt."].contains(where: lower.contains) {
                    result.findings.append("deceptive_double_extension"); result.high = true
                }
            }
            offset = next
        }
        if offset != central.count { return limited("archive_extra_directory_data") }
        result.findings = Array(Set(result.findings)).sorted()
        return result
    }
    private static func unsafePath(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return normalized.hasPrefix("/") || normalized.hasPrefix("~/") || normalized.contains("\0") ||
            components.contains("..") || (components.first?.contains(":") ?? false)
    }
    private static func read(fd: Int32, offset: Int64, count: Int) -> Data? {
        guard count >= 0, offset >= 0 else { return nil }
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { buffer in pread(fd, buffer.baseAddress, count, off_t(offset)) }
        return received == count ? data : nil
    }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
