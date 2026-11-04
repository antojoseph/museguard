import CryptoKit
import Darwin
import Foundation
import Security

enum LocalModelProvisioning {
    struct Asset {
        let name: String
        let filename: String
        let size: Int64
        let sha256: String
    }

    static let revision = "b44f1072cf75e918a1b82a3a17b45c4389b076e7"
    static let assets = [
        Asset(name: "Muse Glimmer", filename: LocalModelConfiguration.mainModelFilename, size: 16_756_683_904,
              sha256: "4cc57c0f51040a226e5a72cc47b7613f7772950e460a665f7083de89f183f60e"),
        Asset(name: "Vision encoder", filename: LocalModelConfiguration.visionModelFilename, size: 1_400_328_928,
              sha256: "f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6"),
        Asset(name: "DFlash draft model", filename: LocalModelConfiguration.draftModelFilename, size: 1_631_208_128,
              sha256: "b2e808bf656086fe86bd0d0bd990f01d33e377537a07c02d45371517c8b264ef")
    ]
    static let totalSize = assets.reduce(Int64(0)) { $0 + $1.size }

    static var bundledServer: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalInference/llama-server")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func weightsReady(in root: URL) -> Bool {
        assets.allSatisfy { size(of: root.appendingPathComponent("weights/\($0.filename)")) == $0.size }
    }

    enum InstallError: LocalizedError {
        case busy, storage, credentials, download(String, Int32), integrity(String)
        var errorDescription: String? {
            switch self {
            case .busy: return "A model setup is already in progress."
            case .storage: return "Free at least 22 GB for model setup, then try again."
            case .credentials: return "Muse could not create its private local credential."
            case let .download(name, status): return "\(name) download stopped (\(status)). Check your connection and choose Resume download."
            case let .integrity(name): return "\(name) failed verification. Choose Resume download to retry that file."
            }
        }
    }

    /// Only immutable public weights come from the network. The server key is
    /// generated on this Mac and is never copied from the build machine.
    static func ensureCredential(in root: URL) throws {
        try privateDirectory(root)
        let key = root.appendingPathComponent("api-key")
        if FileManager.default.isReadableFile(atPath: key.path) { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw InstallError.credentials
        }
        let descriptor = open(key.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST, FileManager.default.isReadableFile(atPath: key.path) { return }
            throw InstallError.credentials
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(Data(bytes).base64EncodedString().utf8))
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: key)
            throw InstallError.credentials
        }
    }

    static func install(in root: URL, progress: @Sendable (String, Int64) async -> Void) async throws {
        let weights = root.appendingPathComponent("weights", isDirectory: true)
        try privateDirectory(root)
        try privateDirectory(weights)
        let lock = open(root.appendingPathComponent("setup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw InstallError.busy }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw InstallError.busy }

        let remaining = assets.reduce(Int64(0)) { total, asset in
            let final = weights.appendingPathComponent(asset.filename)
            let partial = final.appendingPathExtension("partial")
            let present = size(of: partial)
            return size(of: final) == asset.size ? total : total + asset.size - (present <= asset.size ? present : 0)
        }
        if let available = try? weights.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(available) < remaining + 1_000_000_000 { throw InstallError.storage }

        var completed: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            let final = weights.appendingPathComponent(asset.filename)
            if size(of: final) != asset.size {
                let partial = final.appendingPathExtension("partial")
                if size(of: partial) > asset.size { try FileManager.default.removeItem(at: partial) }
                if size(of: partial) < asset.size {
                    try await download(asset, to: partial, completed: completed, progress: progress)
                }
                await progress("Verifying \(asset.name)…", completed + asset.size)
                guard size(of: partial) == asset.size, try sha256(of: partial) == asset.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw InstallError.integrity(asset.name)
                }
                try Task.checkCancellation()
                guard chmod(partial.path, 0o600) == 0, rename(partial.path, final.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            completed += asset.size
        }
        try ensureCredential(in: root)
    }

    private static func download(_ asset: Asset, to partial: URL, completed: Int64,
                                 progress: @Sendable (String, Int64) async -> Void) async throws {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let url = "https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF/resolve/\(revision)/\(asset.filename)"
        var arguments = ["--disable", "--fail", "--location", "--silent", "--proto", "=https", "--proto-redir", "=https",
                         "--connect-timeout", "20", "--speed-limit", "1024", "--speed-time", "45", "--max-filesize", String(asset.size)]
        if size(of: partial) > 0 { arguments += ["--continue-at", "-"] }
        curl.arguments = arguments + ["--output", partial.path, url]
        curl.standardOutput = FileHandle.nullDevice
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        do {
            while curl.isRunning {
                await progress("Downloading \(asset.name)…", completed + min(asset.size, size(of: partial)))
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        } catch {
            if curl.isRunning { curl.terminate(); curl.waitUntilExit() }
            throw error
        }
        guard curl.terminationStatus == 0 else { throw InstallError.download(asset.name, curl.terminationStatus) }
    }

    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func size(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return 0 }
        return info.st_size
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
