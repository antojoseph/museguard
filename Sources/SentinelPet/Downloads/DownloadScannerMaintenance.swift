import Foundation
import Darwin

enum DownloadDefinitionUpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60
    static func delay(now: Date, lastAttempt: Date?, lastSuccess: Date? = nil) -> TimeInterval {
        guard let lastAttempt = [lastAttempt, lastSuccess].compactMap({ $0 }).max() else { return 0 }
        // A clock rollback must not cause a rapid retry loop.
        return min(interval, max(0, interval - now.timeIntervalSince(lastAttempt)))
    }
}

/// Maintains official local definitions; never installs software or scans files.
@MainActor final class DownloadScannerMaintenance {
    private let preferences: UserDefaults
    private let base: URL
    private let lastAttemptKey = "downloadDefinitions.lastAttempt.v1"
    private let lastSuccessKey = "downloadDefinitions.lastSuccess.v1"
    private var task: Task<Void, Never>?
    private var cancellation: DownloadInspectionCancellation?
    private var generation = 0

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MuseGuard/DownloadScanner", isDirectory: true)
    }

    func start(isEnabled: @escaping () -> Bool, onStatus: @escaping (String) -> Void) {
        guard task == nil else { return }
        generation += 1
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil; self.cancellation = nil } }
            while !Task.isCancelled && self.generation == token && isEnabled() {
                let now = Date()
                var last = self.preferences.object(forKey: self.lastAttemptKey) as? Date
                var success = self.preferences.object(forKey: self.lastSuccessKey) as? Date
                // Repair a persisted future timestamp conservatively after a
                // clock change: wait a full day from now instead of forever.
                if let value = last, value > now { last = now; self.preferences.set(now, forKey: self.lastAttemptKey) }
                if let value = success, value > now { success = now; self.preferences.set(now, forKey: self.lastSuccessKey) }
                let delay = DownloadDefinitionUpdateSchedule.delay(now: now, lastAttempt: last, lastSuccess: success)
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(min(delay, 60 * 60) * 1_000_000_000)) }
                    catch { return }
                    continue
                }
                // Persist before launching so failures, pauses and app restarts
                // cannot hammer the official CDN or reset its own cooldown.
                self.preferences.set(now, forKey: self.lastAttemptKey)
                guard let configuration = DownloadDefinitionUpdateConfiguration.load(base: self.base) else {
                    onStatus("Local malware definition updates are unavailable; set up the download scanner.")
                    continue
                }
                let owner = DownloadInspectionCancellation()
                self.cancellation = owner
                onStatus("Updating local malware definitions from ClamAV.")
                do {
                    let result = try await withTaskCancellationHandler(operation: {
                        try await Task.detached(priority: .utility) {
                            try DownloadCommand.run(executable: configuration.executable,
                                arguments: ["--config-file=\(configuration.config.path)", "--cvdcertsdir=\(configuration.certificates.path)", "--stdout"],
                                inputFD: nil, timeout: 600, cancellation: owner,
                                environment: ["CVD_CERTS_DIR": configuration.certificates.path])
                        }.value
                    }, onCancel: { owner.cancel() })
                    guard !Task.isCancelled, self.generation == token, isEnabled() else { return }
                    self.cancellation = nil
                    if result.status == 0 && !result.timedOut && !result.truncated {
                        self.preferences.set(Date(), forKey: self.lastSuccessKey)
                        onStatus("Local malware definitions are up to date.")
                    } else {
                        onStatus("Local malware definitions could not update; the next attempt is tomorrow.")
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == token, isEnabled() else { return }
                    self.cancellation = nil
                    onStatus("Local malware definitions could not update; the next attempt is tomorrow.")
                }
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        cancellation?.cancel(); cancellation = nil
    }
}

struct DownloadDefinitionUpdateConfiguration {
    let executable: URL
    let config: URL
    let certificates: URL

    static func load(base: URL) -> Self? {
        let executable = base.appendingPathComponent("clamav/bin/freshclam")
        let config = base.appendingPathComponent("freshclam.conf")
        let certificates = base.appendingPathComponent("clamav/etc/certs", isDirectory: true)
        let database = base.appendingPathComponent("database", isDirectory: true)
        let fm = FileManager.default
        for file in [executable, config, certificates.appendingPathComponent("clamav.crt")] {
            guard file.standardizedFileURL == file.resolvingSymlinksInPath(),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o022 == 0 else { return nil }
        }
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        let header = (try? handle.read(upToCount: 4)) ?? Data()
        try? handle.close()
        let magic = [UInt8](header).map(Int.init)
        guard [[0xfe,0xed,0xfa,0xce],[0xfe,0xed,0xfa,0xcf],[0xce,0xfa,0xed,0xfe],[0xcf,0xfa,0xed,0xfe],
            [0xca,0xfe,0xba,0xbe],[0xbe,0xba,0xfe,0xca],[0xca,0xfe,0xba,0xbf],[0xbf,0xba,0xfe,0xca]].contains(magic) else { return nil }
        guard fm.isExecutableFile(atPath: executable.path),
              let attributes = try? fm.attributesOfItem(atPath: config.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let content = try? String(contentsOf: config, encoding: .utf8),
              validConfig(content, database: database.path, certificates: certificates.path, user: NSUserName()) else { return nil }
        return .init(executable: executable, config: config, certificates: certificates)
    }

    /// Accept the setup script's small official-only configuration. In
    /// particular, no updater execute hooks, custom URLs or private mirrors.
    static func validConfig(_ content: String, database: String, certificates: String, user: String) -> Bool {
        let expected = ["DatabaseDirectory": database, "CVDCertsDirectory": certificates,
            "DatabaseMirror": "database.clamav.net", "DatabaseOwner": user,
            "ConnectTimeout": "30", "ReceiveTimeout": "120", "MaxAttempts": "1",
            "TestDatabases": "yes", "ScriptedUpdates": "yes", "LogTime": "yes"]
        var found = Set<String>()
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let split = line.firstIndex(where: { $0.isWhitespace }) else { return false }
            let key = String(line[..<split])
            var value = line[split...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value.removeFirst(); value.removeLast() }
            guard expected[key] == value, found.insert(key).inserted else { return false }
        }
        return found == Set(expected.keys)
    }
}
