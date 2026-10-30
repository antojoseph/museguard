import Foundation
import CryptoKit
import Darwin

// Only Chrome's download metadata crosses the bridge. File contents remain in
// this process and, when configured, the local ClamAV process.
enum DownloadInspectionPhase: String, Codable { case metadata, complete }
struct DownloadInspectionInput {
    let downloadID: Int
    let phase: DownloadInspectionPhase
    let url: String?
    let finalURL: String?
    let filename: String?
    let mime: String?
    let state: String
    let danger: String?
    let fileSize: Int64?
    let totalBytes: Int64?
    init(downloadID: Int, phase: DownloadInspectionPhase, url: String? = nil, finalURL: String? = nil,
         filename: String? = nil, mime: String? = nil, state: String,
         danger: String? = nil, fileSize: Int64? = nil, totalBytes: Int64? = nil) {
        self.downloadID = downloadID; self.phase = phase; self.url = url; self.finalURL = finalURL
        self.filename = filename; self.mime = mime; self.state = state; self.danger = danger
        self.fileSize = fileSize; self.totalBytes = totalBytes
    }
}
struct DownloadInspectionLimits {
    var maximumFileBytes: Int64 = 256 * 1_024 * 1_024
    var maximumArchiveBytes: Int64 = 512 * 1_024 * 1_024
    var maximumArchiveEntries = 1_000
    var maximumCentralDirectoryBytes = 4 * 1_024 * 1_024
    var maximumCommandSeconds: Double = 45
    static let `default` = DownloadInspectionLimits()
}
struct DownloadInspectionDetails: Codable {
    let downloadID: Int
    let status: String
    let sha256: String?
    let scanner: String
    let scanStatus: String
    let findings: [String]
    let signatureStatus: String
    enum CodingKeys: String, CodingKey {
        case downloadID = "download_id", status, sha256, scanner
        case scanStatus = "scan_status", findings, signatureStatus = "signature_status"
    }
}
struct DownloadInspectionResult {
    let riskLevel: RiskLevel
    let summary: String
    let guidance: String
    let categories: [String]
    let details: DownloadInspectionDetails
}

final class DownloadInspector: @unchecked Sendable {
    private let allowedDirectories: [URL]
    private let scannerExecutable: URL?
    private let scannerDatabase: URL?
    private let limits: DownloadInspectionLimits
    private let scannerSlot = DispatchSemaphore(value: 1)
    init(allowedDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)],
         scannerExecutable: URL? = DownloadInspector.installedScanner(), scannerDatabase: URL? = nil,
         limits: DownloadInspectionLimits = .default) {
        self.allowedDirectories = allowedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.scannerExecutable = scannerExecutable
        self.scannerDatabase = scannerDatabase ?? Self.databaseForScanner(scannerExecutable)
        self.limits = limits
    }
    static func installedScanner() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clamav/bin/clamscan")
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/DownloadScanner/clamav/bin/clamscan")
        return [bundled.path, local.path, "/opt/homebrew/bin/clamscan", "/usr/local/bin/clamscan"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    private static func databaseForScanner(_ scanner: URL?) -> URL? {
        guard let scanner else { return nil }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/DownloadScanner")
        let local = base.appendingPathComponent("clamav/bin/clamscan")
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clamav/bin/clamscan")
        return scanner.standardizedFileURL == local.standardizedFileURL || scanner.standardizedFileURL == bundled.standardizedFileURL ?
            base.appendingPathComponent("database", isDirectory: true) : nil
    }
    func inspect(_ input: DownloadInspectionInput) async throws -> DownloadInspectionResult {
        let cancellation = DownloadInspectionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) { [self] in
                try inspectSynchronously(input, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
    }
    private func inspectSynchronously(_ input: DownloadInspectionInput, cancellation: DownloadInspectionCancellation) throws -> DownloadInspectionResult {
        try cancellation.check()
        var findings: [String] = []
        var high = false
        let knownDanger = ["url", "content", "host", "unwanted", "deepScannedOpenedDangerous", "sensitiveContentBlock", "accountCompromise"]
        if knownDanger.contains(input.danger ?? "") { findings.append("browser_reported_danger"); high = true }
        if ["file", "uncommon", "passwordProtected", "blockedTooLarge", "deepScannedFailed", "blockedScanFailed"].contains(input.danger ?? "") {
            findings.append("browser_requires_review")
        }
        if let filename = input.filename { classifyName(URL(fileURLWithPath: filename).lastPathComponent, findings: &findings, high: &high) }
        guard input.phase == .complete else {
            return result(input, status: "metadata_only", findings: findings, high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_applicable")
        }
        guard input.state == "complete", let filename = input.filename,
              filename.hasPrefix("/"), !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return result(input, status: "rejected", findings: findings + ["invalid_completed_path"], high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_checked")
        }
        let requested = URL(fileURLWithPath: filename).standardizedFileURL
        let canonical = requested.resolvingSymlinksInPath()
        guard let allowedRoot = allowedDirectories.first(where: { canonical.path.hasPrefix($0.path + "/") }),
              canonical.path == requested.path else {
            return result(input, status: "rejected", findings: findings + ["path_outside_downloads_or_symlink"], high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_checked")
        }
        let fd = openDownload(canonical, beneath: allowedRoot)
        guard fd >= 0 else {
            return result(input, status: "unavailable", findings: findings + ["file_unreadable"], high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_checked")
        }
        defer { Darwin.close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            return result(input, status: "rejected", findings: findings + ["not_regular_file"], high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_checked")
        }
        guard initial.st_size >= 0, initial.st_size <= limits.maximumFileBytes else {
            return result(input, status: "limited", findings: findings + ["file_size_limit"], high: high,
                scanStatus: "limited", scanner: "unavailable", signature: "not_checked")
        }
        guard input.fileSize == nil || input.fileSize! < 0 || input.fileSize == initial.st_size else {
            return result(input, status: "changed", findings: findings + ["file_size_changed"], high: high,
                scanStatus: "unavailable", scanner: "unavailable", signature: "not_checked")
        }
        var hasher = SHA256(), header = Data(), count: Int64 = 0
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
        defer { readBuffer.deallocate() }
        while true {
            try cancellation.check()
            let size = Darwin.read(fd, readBuffer, 1_048_576)
            guard size >= 0 else { throw DownloadInspectionError.readFailed }
            if size == 0 { break }
            count += Int64(size)
            if count > limits.maximumFileBytes { throw DownloadInspectionError.fileChanged }
            let chunk = Data(bytes: readBuffer, count: size)
            if header.count < 4_096 { header.append(chunk.prefix(4_096 - header.count)) }
            hasher.update(data: chunk)
        }
        guard count == initial.st_size, unchanged(fd: fd, path: canonical.path, initial: initial) else { throw DownloadInspectionError.fileChanged }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let testPattern = Data("X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8)
        let eicarTest = header.range(of: testPattern) != nil
        if eicarTest { findings.append("eicar_antivirus_test"); high = true }
        let kind = contentKind(header)
        let ext = canonical.pathExtension.lowercased()
        if ["macho", "pe", "script"].contains(kind) {
            findings.append("executable_content")
            if ["pdf", "png", "jpg", "jpeg", "gif", "txt", "rtf", "doc", "docx", "xlsx"].contains(ext) {
                findings.append("document_disguises_executable"); high = true
            }
        }
        var incomplete = false
        if kind == "zip" {
            let archive = DownloadZipInspection.inspect(fd: fd, size: count, limits: limits)
            findings += archive.findings; high = high || archive.high; incomplete = archive.limited
        }
        var signature = "not_applicable"
        if kind == "macho" {
            let signatureResult = try DownloadCommand.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", "--verbose=2", canonical.path], inputFD: nil,
                timeout: min(10, limits.maximumCommandSeconds), cancellation: cancellation)
            if signatureResult.timedOut || signatureResult.truncated { signature = "unavailable" }
            else if signatureResult.status == 0 { signature = "valid" }
            else if signatureResult.output.contains("not signed at all") { signature = "unsigned"; findings.append("unsigned_executable") }
            else { signature = "invalid"; findings.append("invalid_code_signature") }
        }
        var scanStatus = "unavailable", scanner = "unavailable"
        if let scannerExecutable, FileManager.default.isExecutableFile(atPath: scannerExecutable.path) {
            scanner = "clamav"
            // A definition database can occupy substantial memory. Keep one
            // ClamAV process per inspector while metadata checks stay fast.
            while scannerSlot.wait(timeout: .now() + 0.1) != .success { try cancellation.check() }
            defer { scannerSlot.signal() }
            try cancellation.check()
            let maxFile = max(1, limits.maximumFileBytes / 1_024 / 1_024)
            let maxScan = max(1, limits.maximumArchiveBytes / 1_024 / 1_024)
            var args = ["--no-summary", "--infected", "--stdout", "--scan-archive=yes", "--alert-exceeds-max=yes", "--alert-encrypted=yes",
                "--max-filesize=\(maxFile)M", "--max-scansize=\(maxScan)M", "--max-files=\(limits.maximumArchiveEntries)", "--max-recursion=12", "--max-scantime=\(Int(limits.maximumCommandSeconds * 900))"]
            if let scannerDatabase { args.append("--database=\(scannerDatabase.path)") }
            let certificates = scannerExecutable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("etc/certs", isDirectory: true)
            if FileManager.default.fileExists(atPath: certificates.path) { args.append("--cvdcertsdir=\(certificates.path)") }
            args.append("-")
            _ = lseek(fd, 0, SEEK_SET)
            let scan = try DownloadCommand.run(executable: scannerExecutable, arguments: args, inputFD: fd,
                timeout: limits.maximumCommandSeconds, cancellation: cancellation)
            let lines = scan.output.components(separatedBy: .newlines)
            let malware = lines.filter { $0.hasSuffix(" FOUND") && !$0.contains("Heuristics.Limits.Exceeded") && !$0.contains("Heuristics.Encrypted") }
            if !malware.isEmpty {
                scanStatus = "infected"; high = true; findings.append(eicarTest ? "clamav_eicar_test" : "malware_signature_detected")
            } else if scan.timedOut || scan.truncated {
                scanStatus = "error"; findings.append(scan.timedOut ? "scanner_timeout" : "scanner_output_limit")
            } else if scan.output.contains("Heuristics.Limits.Exceeded") || scan.output.contains("Heuristics.Encrypted") ||
                        scan.output.lowercased().contains("database is older") {
                scanStatus = "limited"; incomplete = true; findings.append("scanner_coverage_limited")
            } else if scan.status == 0 && lines.contains(where: { $0.lowercased().contains("warning:") || $0.lowercased().contains("error:") }) {
                scanStatus = "limited"; incomplete = true; findings.append("scanner_coverage_warning")
            } else if scan.status == 0 { scanStatus = "clean" }
            else { scanStatus = "error"; findings.append("scanner_error") }
        } else if eicarTest { scanner = "builtin_eicar_test"; scanStatus = "infected" }
        else { findings.append("malware_scanner_unavailable") }
        try cancellation.check()
        guard unchanged(fd: fd, path: canonical.path, initial: initial) else { throw DownloadInspectionError.fileChanged }
        if incomplete && scanStatus == "clean" { scanStatus = "limited" }
        let status = scanStatus == "unavailable" ? "unavailable" : (incomplete || scanStatus == "limited" ? "limited" : (scanStatus == "error" ? "unavailable" : "scanned"))
        return result(input, status: status, findings: findings, high: high, scanStatus: scanStatus, scanner: scanner,
            signature: signature, sha256: digest)
    }
    private func openDownload(_ file: URL, beneath root: URL) -> Int32 {
        // Holding each directory descriptor and refusing symlinks at every
        // step prevents a parent-directory swap from escaping the allowlist.
        let components = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard let last = components.last else { return -1 }
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return -1 }
        defer { Darwin.close(directory) }
        for name in components.dropLast() {
            let next = Darwin.openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { return -1 }
            Darwin.close(directory); directory = next
        }
        return Darwin.openat(directory, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    private func unchanged(fd: Int32, path: String, initial: stat) -> Bool {
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(path, &named) == 0 else { return false }
        return current.st_dev == initial.st_dev && current.st_ino == initial.st_ino && current.st_size == initial.st_size &&
            current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec && current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec &&
            current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec && current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec &&
            named.st_dev == initial.st_dev && named.st_ino == initial.st_ino && named.st_mode & S_IFMT == S_IFREG
    }
    private func classifyName(_ name: String, findings: inout [String], high: inout Bool) {
        let lower = name.lowercased(), ext = (name as NSString).pathExtension.lowercased()
        let executables = ["app", "command", "sh", "bash", "zsh", "scpt", "pkg", "dmg", "exe", "msi", "scr", "bat", "cmd", "ps1", "vbs", "js", "jar"]
        if executables.contains(ext) { findings.append("executable_download") }
        if executables.contains(ext), [".pdf.", ".jpg.", ".jpeg.", ".png.", ".doc.", ".docx.", ".txt."].contains(where: lower.contains) {
            findings.append("deceptive_double_extension"); high = true
        }
        if name.unicodeScalars.contains(where: { [0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069].contains($0.value) }) {
            findings.append("bidirectional_filename"); if executables.contains(ext) { high = true }
        }
    }
    private func contentKind(_ header: Data) -> String {
        let bytes = [UInt8](header.prefix(4))
        if bytes.count >= 2 && bytes[0] == 0x4d && bytes[1] == 0x5a { return "pe" }
        if bytes.count >= 2 && bytes[0] == 0x23 && bytes[1] == 0x21 { return "script" }
        if bytes.count == 4 && [[0xfe,0xed,0xfa,0xce],[0xfe,0xed,0xfa,0xcf],[0xce,0xfa,0xed,0xfe],[0xcf,0xfa,0xed,0xfe],[0xca,0xfe,0xba,0xbe],[0xbe,0xba,0xfe,0xca]].contains(bytes.map(Int.init)) { return "macho" }
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && [0x03,0x05,0x07].contains(bytes[2]) { return "zip" }
        return "other"
    }
    private func result(_ input: DownloadInspectionInput, status: String, findings: [String], high: Bool,
        scanStatus: String, scanner: String, signature: String, sha256: String? = nil) -> DownloadInspectionResult {
        let unique = Array(Set(findings)).sorted()
        let risk: RiskLevel = high ? .high : (!unique.filter { !["malware_scanner_unavailable"].contains($0) }.isEmpty ? .medium : (scanStatus == "clean" ? .low : .unknown))
        let summary: String, guidance: String
        if unique.contains("eicar_antivirus_test") {
            summary = "This download contains the standard antivirus test pattern."
            guidance = "This is a harmless test detection. Do not open it as a normal download; cancel the test download or remove the fixture yourself."
        } else if scanStatus == "infected" {
            summary = "The local malware scanner found a malicious-file signature."
            guidance = "Do not open this file. Cancel the download or remove it using Finder. Muse has not opened or deleted it."
        } else if high {
            summary = "This download has a concrete danger indicator."
            if unique.contains("deceptive_double_extension") || unique.contains("document_disguises_executable") {
                guidance = "The apparent document is executable content. Do not open it; verify the download through its official source."
            } else if unique.contains("archive_path_traversal") { guidance = "The archive contains paths outside its extraction folder. Do not extract it." }
            else { guidance = "Chrome reports this download as dangerous. Do not bypass Chrome’s warning or open the file." }
        } else if scanStatus == "clean" {
            summary = "The local malware scan found no known signature in this file."
            guidance = "This is not a guarantee of safety. Open files only when you expected them and trust their source."
        } else if input.phase == .metadata {
            summary = "Download metadata checked; the file has not been scanned yet."
            guidance = "Muse will inspect the completed file when it is available in Downloads."
        } else {
            summary = status == "rejected" ? "Muse could not inspect this download path." : "This download has not received a complete malware scan."
            guidance = scanStatus == "unavailable" ? "The local malware scanner is unavailable, or this file is outside Downloads. Treat the file as unassessed; do not open an unexpected download." : "The scan was incomplete or hit a limit. Treat the file as unassessed and verify its source before opening it."
        }
        return DownloadInspectionResult(riskLevel: risk, summary: summary, guidance: guidance,
            categories: unique, details: .init(downloadID: input.downloadID, status: status, sha256: sha256,
                scanner: scanner, scanStatus: scanStatus, findings: unique, signatureStatus: signature))
    }
}

enum DownloadInspectionError: LocalizedError {
    case readFailed, fileChanged
    var errorDescription: String? {
        switch self { case .readFailed: return "The download could not be read completely."; case .fileChanged: return "The download changed while it was being checked. Retry the completed file." }
    }
}

final class DownloadInspectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
    func launch(_ process: Process) throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; self.process = process; try process.run() }
    func clear(_ process: Process) { lock.lock(); if self.process === process { self.process = nil }; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        if let active, active.isRunning { active.terminate(); let pid = active.processIdentifier; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if active.isRunning { kill(pid, SIGKILL) } } }
    }
}

struct DownloadCommandResult { let status: Int32; let output: String; let timedOut: Bool; let truncated: Bool }
enum DownloadCommand {
    static func run(executable: URL, arguments: [String], inputFD: Int32?, timeout: TimeInterval,
        cancellation: DownloadInspectionCancellation, environment: [String: String] = [:]) throws -> DownloadCommandResult {
        try cancellation.check()
        let process = Process(), pipe = Pipe(), buffer = DownloadOutputBuffer()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        process.standardOutput = pipe; process.standardError = pipe
        let input = inputFD.flatMap { fd -> FileHandle? in let copy = dup(fd); return copy >= 0 ? FileHandle(fileDescriptor: copy, closeOnDealloc: true) : nil }
        process.standardInput = input ?? FileHandle.nullDevice
        defer { cancellation.clear(process); try? input?.close(); pipe.fileHandleForReading.readabilityHandler = nil }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard buffer.beginRead() else { return }
            defer { buffer.endRead() }
            let bytes = handle.availableData
            if !bytes.isEmpty { buffer.append(bytes) }
        }
        try cancellation.launch(process)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.01, timeout))
        timer.setEventHandler {
            if process.isRunning {
                buffer.timeout(); process.terminate(); let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(pid, SIGKILL) } }
            }
        }
        timer.resume()
        process.waitUntilExit(); timer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.finishReading()
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        try cancellation.check()
        return DownloadCommandResult(status: process.terminationStatus, output: buffer.value, timedOut: buffer.timedOut, truncated: buffer.truncated)
    }
}
private final class DownloadOutputBuffer: @unchecked Sendable {
    private let lock = NSCondition(); private var data = Data(); private var didTimeout = false; private var didTruncate = false
    private var readers = 0; private var finishedReading = false
    func beginRead() -> Bool { lock.lock(); defer { lock.unlock() }; guard !finishedReading else { return false }; readers += 1; return true }
    func endRead() { lock.lock(); readers -= 1; lock.broadcast(); lock.unlock() }
    func finishReading() { lock.lock(); finishedReading = true; while readers > 0 { lock.wait() }; lock.unlock() }
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; let available = max(0, 262_144 - data.count); data.append(value.prefix(available)); if value.count > available { didTruncate = true } }
    func timeout() { lock.lock(); didTimeout = true; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeout }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
}
