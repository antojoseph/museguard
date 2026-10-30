import Foundation
import Darwin

@main struct DownloadInspectionChecks {
    static func zip(name: String, localName: String? = nil, extra: Data = Data(), flags: UInt16 = 0, expanded: UInt32 = 1, mode: UInt32 = 0) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)]) }
        func u32(_ value: UInt32) { data.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8(value >> 24)]) }
        let bytes = Data(name.utf8)
        let localBytes = Data((localName ?? name).utf8)
        u32(0x04034b50);u16(20);u16(flags);u16(0);u16(0);u16(0);u32(0);u32(1);u32(expanded);u16(UInt16(localBytes.count));u16(0);data.append(localBytes);data.append(0)
        let offset = UInt32(data.count)
        u32(0x02014b50);u16(0x0314);u16(20);u16(flags);u16(0);u16(0);u16(0);u32(0);u32(1);u32(expanded);u16(UInt16(bytes.count));u16(UInt16(extra.count));u16(0);u16(0);u16(0);u32(mode << 16);u32(0);data.append(bytes);data.append(extra)
        let size = UInt32(data.count) - offset
        u32(0x06054b50);u16(0);u16(0);u16(1);u16(1);u32(size);u32(offset);u16(0)
        return data
    }
    static func main() async throws {
        let scheduleNow = Date(timeIntervalSince1970: 1_000_000)
        assert(DownloadDefinitionUpdateSchedule.delay(now: scheduleNow, lastAttempt: nil) == 0)
        assert(DownloadDefinitionUpdateSchedule.delay(now: scheduleNow, lastAttempt: scheduleNow) == 86_400)
        assert(DownloadDefinitionUpdateSchedule.delay(now: scheduleNow, lastAttempt: scheduleNow.addingTimeInterval(-86_400)) == 0)
        assert(DownloadDefinitionUpdateSchedule.delay(now: scheduleNow, lastAttempt: scheduleNow.addingTimeInterval(600)) == 86_400)
        assert(DownloadDefinitionUpdateSchedule.delay(now: scheduleNow, lastAttempt: scheduleNow.addingTimeInterval(-600), lastSuccess: scheduleNow) == 86_400)
        let updateConfig = """
        DatabaseDirectory "/fixture/definitions"
        CVDCertsDirectory "/fixture/certs"
        DatabaseMirror database.clamav.net
        DatabaseOwner fixture
        ConnectTimeout 30
        ReceiveTimeout 120
        MaxAttempts 1
        TestDatabases yes
        ScriptedUpdates yes
        LogTime yes
        """
        assert(DownloadDefinitionUpdateConfiguration.validConfig(updateConfig, database: "/fixture/definitions", certificates: "/fixture/certs", user: "fixture"))
        assert(!DownloadDefinitionUpdateConfiguration.validConfig(updateConfig + "\nOnUpdateExecute /bin/sh", database: "/fixture/definitions", certificates: "/fixture/certs", user: "fixture"))
        assert(!DownloadDefinitionUpdateConfiguration.validConfig(updateConfig.replacingOccurrences(of: "database.clamav.net", with: "private.example"), database: "/fixture/definitions", certificates: "/fixture/certs", user: "fixture"))
        assert(!DownloadDefinitionUpdateConfiguration.validConfig(updateConfig + "\nDatabaseMirror database.clamav.net", database: "/fixture/definitions", certificates: "/fixture/certs", user: "fixture"))
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("muse-download-check-" + UUID().uuidString, isDirectory: true)
        let allowed = temp.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func file(_ name: String, _ bytes: Data) throws -> URL {
            let path = allowed.appendingPathComponent(name); try bytes.write(to: path); return path
        }
        func input(_ url: URL, size: Int64? = nil) -> DownloadInspectionInput {
            .init(downloadID: 7, phase: .complete, url: "https://example.test/file", filename: url.path,
                state: "complete", danger: "safe", fileSize: size)
        }
        func scanner(_ name: String, script: String) throws -> URL {
            let path = temp.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: path)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path
        }
        let inspector = DownloadInspector(allowedDirectories: [allowed], scannerExecutable: nil)
        let hello = try file("hello.txt", Data("hello".utf8))
        let unknown = try await inspector.inspect(input(hello))
        assert(unknown.riskLevel == .unknown && unknown.details.scanStatus == "unavailable")
        assert(unknown.details.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        assert(unknown.summary.contains("not received a complete"))
        let metadata = try await inspector.inspect(.init(downloadID: 1, phase: .metadata, filename: "invoice.pdf.command", state: "in_progress"))
        assert(metadata.riskLevel == .high && metadata.details.status == "metadata_only" && metadata.details.sha256 == nil)
        let chromeDanger = try await inspector.inspect(.init(downloadID: 2, phase: .metadata, state: "in_progress", danger: "content"))
        assert(chromeDanger.riskLevel == .high)
        let ordinary = try await inspector.inspect(.init(downloadID: 3, phase: .metadata, filename: "photo.jpg", state: "in_progress"))
        assert(ordinary.riskLevel == .unknown && ordinary.details.scanStatus != "clean")

        let outside = temp.appendingPathComponent("private.txt"); try Data("not a download".utf8).write(to: outside)
        let rejected = try await inspector.inspect(input(outside))
        assert(rejected.details.status == "rejected" && rejected.details.sha256 == nil)
        let linked = allowed.appendingPathComponent("linked.txt")
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        let symlink = try await inspector.inspect(input(linked))
        assert(symlink.details.status == "rejected")
        let fifo = allowed.appendingPathComponent("pipe")
        assert(mkfifo(fifo.path, 0o600) == 0)
        let special = try await inspector.inspect(input(fifo))
        assert(special.details.status == "rejected", "A FIFO must never block or be inspected as a file.")
        var smallLimits = DownloadInspectionLimits.default; smallLimits.maximumFileBytes = 4
        let bounded = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: nil, limits: smallLimits).inspect(input(hello))
        assert(bounded.details.status == "limited" && bounded.details.sha256 == nil)
        let changedSize = try await inspector.inspect(input(hello, size: 99))
        assert(changedSize.details.status == "changed" && changedSize.details.sha256 == nil)
        let executable = try file("statement.pdf", Data([0x4d, 0x5a, 0, 0]) + Data("synthetic non-executed fixture".utf8))
        let disguised = try await inspector.inspect(input(executable))
        assert(disguised.riskLevel == .high && disguised.categories.contains("document_disguises_executable"))
        let eicar = try file("antivirus-test.txt", Data("X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8))
        let testPattern = try await inspector.inspect(input(eicar))
        assert(testPattern.riskLevel == .high && testPattern.details.scanner == "builtin_eicar_test")
        assert(testPattern.summary.contains("test pattern"), "The built-in test detector must not pretend to be a full malware engine.")

        let traversal = try file("traversal.zip", zip(name: "../outside.txt"))
        let badZip = try await inspector.inspect(input(traversal))
        assert(badZip.riskLevel == .high && badZip.categories.contains("archive_path_traversal"))
        let mismatched = try file("local-traversal.zip", zip(name: "safe.txt", localName: "../a.txt"))
        let localTraversal = try await inspector.inspect(input(mismatched))
        assert(localTraversal.riskLevel == .high && localTraversal.categories.contains("archive_filename_mismatch"))
        // Info-ZIP path override: version 1, legacy-name CRC, Unicode name.
        let unicodeName = Data("../outside.txt".utf8)
        let extraLength = UInt16(unicodeName.count + 5)
        var unicodeExtra = Data([0x75, 0x70, UInt8(extraLength & 255), UInt8(extraLength >> 8), 1, 0, 0, 0, 0])
        unicodeExtra.append(unicodeName)
        let overridden = try file("unicode-traversal.zip", zip(name: "safe.txt", extra: unicodeExtra))
        let unicodeTraversal = try await inspector.inspect(input(overridden))
        assert(unicodeTraversal.riskLevel == .high && unicodeTraversal.categories.contains("archive_path_traversal"))
        let encrypted = try file("encrypted.zip", zip(name: "file.txt", flags: 1))
        let secretZip = try await inspector.inspect(input(encrypted))
        assert(secretZip.categories.contains("archive_encrypted") && secretZip.details.scanStatus != "clean")
        let bomb = try file("expansion.zip", zip(name: "file.txt", expanded: 600 * 1_024 * 1_024))
        let boundedZip = try await inspector.inspect(input(bomb))
        assert(boundedZip.categories.contains("archive_expansion_limit") && boundedZip.details.scanStatus != "clean")
        let innerExecutable = try file("disguised.zip", zip(name: "invoice.pdf.command"))
        let innerResult = try await inspector.inspect(input(innerExecutable))
        assert(innerResult.riskLevel == .high)
        let broken = try file("broken.zip", Data([0x50, 0x4b, 3, 4]) + Data(repeating: 0, count: 30))
        let brokenResult = try await inspector.inspect(input(broken))
        assert(brokenResult.categories.contains("archive_invalid_directory"))

        let cleanTool = try scanner("clean-scanner", script: "/bin/cat >/dev/null\nprintf 'stdin: OK\\n'\nexit 0")
        let clean = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: cleanTool).inspect(input(hello))
        assert(clean.details.scanStatus == "clean" && clean.riskLevel == .low)
        let foundTool = try scanner("finding-scanner", script: "/bin/cat >/dev/null\nprintf 'stdin: Fixture.Trojan FOUND\\n'\nexit 1")
        let infected = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: foundTool).inspect(input(hello))
        assert(infected.riskLevel == .high && infected.details.scanStatus == "infected")
        let limitTool = try scanner("limited-scanner", script: "/bin/cat >/dev/null\nprintf 'stdin: Heuristics.Limits.Exceeded.MaxScanSize FOUND\\n'\nexit 1")
        let limited = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: limitTool).inspect(input(hello))
        assert(limited.details.scanStatus == "limited" && limited.riskLevel != .high, "A scanner limit is not a malware signature.")
        let errorTool = try scanner("error-scanner", script: "printf 'ERROR: database missing\\n'\nexit 2")
        let error = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: errorTool).inspect(input(hello))
        assert(error.details.scanStatus == "error" && error.details.status != "scanned")
        let warningTool = try scanner("warning-scanner", script: "/bin/cat >/dev/null\nprintf 'LibClamAV Warning: archive module not loaded\\n'\nexit 0")
        let warning = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: warningTool).inspect(input(hello))
        assert(warning.details.scanStatus == "limited" && warning.categories.contains("scanner_coverage_warning"))
        let slowTool = try scanner("slow-scanner", script: "exec /bin/sleep 5")
        var fastTimeout = DownloadInspectionLimits.default; fastTimeout.maximumCommandSeconds = 0.05
        let timed = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: slowTool, limits: fastTimeout).inspect(input(hello))
        assert(timed.details.scanStatus == "error" && timed.categories.contains("scanner_timeout"))
        let cancelled = Task { try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: slowTool).inspect(input(hello)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Scanner cancellation must propagate.") }
        catch is CancellationError {}
        let quoted = hello.path.replacingOccurrences(of: "'", with: "'\\''")
        let mutatingTool = try scanner("mutating-scanner", script: "/bin/cat >/dev/null\nprintf x >> '\(quoted)'\nexit 0")
        do { _ = try await DownloadInspector(allowedDirectories: [allowed], scannerExecutable: mutatingTool).inspect(input(hello)); assertionFailure("Changed files cannot receive a clean verdict.") }
        catch DownloadInspectionError.fileChanged {}
        if CommandLine.arguments.contains("--real-clamav") {
            let maintenanceBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/DownloadScanner", isDirectory: true)
            assert(DownloadDefinitionUpdateConfiguration.load(base: maintenanceBase) != nil,
                "The installed official updater, configuration and trust certificate must be eligible for maintenance.")
            let environment = ProcessInfo.processInfo.environment
            let executable = environment["MUSE_CLAMAV_BINARY"].map { URL(fileURLWithPath: $0) } ?? DownloadInspector.installedScanner()
            guard let executable else { fatalError("Real ClamAV check requested but no scanner is installed.") }
            let database = environment["MUSE_CLAMAV_DATABASE"].map { URL(fileURLWithPath: $0) }
            let real = DownloadInspector(allowedDirectories: [allowed], scannerExecutable: executable, scannerDatabase: database)
            let realTest = try await real.inspect(input(eicar))
            assert(realTest.details.scanner == "clamav" && realTest.details.scanStatus == "infected" && realTest.riskLevel == .high,
                "Real local ClamAV and definitions must detect the harmless antivirus test file.")
            let harmless = try file("real-clean.txt", Data("A harmless local download fixture, without credentials or executable content.".utf8))
            let realClean = try await real.inspect(input(harmless))
            assert(realClean.details.scanStatus == "clean" && realClean.riskLevel == .low,
                "Real local ClamAV must finish the ordinary-file scan, not report unavailable as clean.")
            print("PASS: real local ClamAV detects the harmless EICAR test file and completes a clean ordinary-file scan")
        }
        print("PASS: local download path restrictions, descriptor hashing, test signature, deceptive files, bounded archives, scanner statuses, timeout, cancellation and changed-file rejection")
    }
}
