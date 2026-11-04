import CryptoKit
import Darwin
import Foundation

private let hostName = "com.antojoseph.museguard"
private let maxRequestBytes = 2_100_000
private let maxResponseBytes = 1_048_576
private let unavailable = "Muse Guard is unavailable. Open the companion app and try again."

private struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Frame {
    let data: Data
    let object: [String: Any]

    static func read(from fd: Int32, limit: Int) throws -> Frame? {
        guard let header = try readExactly(fd, count: 4, allowEOF: true) else { return nil }
        let count = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard count > 0, count <= limit else { throw HostError("Native message exceeds the local size limit.") }
        guard let body = try readExactly(fd, count: count, allowEOF: false),
              String(data: body, encoding: .utf8) != nil,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HostError("Native message must be a UTF-8 JSON object.")
        }
        return Frame(data: header + body, object: object)
    }

    private static func readExactly(_ fd: Int32, count: Int, allowEOF: Bool) throws -> Data? {
        var data = Data(count: count)
        let complete = try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR { continue }
                if received == 0, offset == 0, allowEOF { return false }
                guard received > 0 else { throw HostError("Incomplete native message.") }
                offset += received
            }
            return true
        }
        return complete ? data : nil
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw HostError("The native connection closed.") }
                offset += written
            }
        }
    }

    static func failure(id: String, mode: String, message: String) -> Data? {
        let response: [String: Any] = [
            "version": 1, "id": id, "ok": false, "decision": "review", "risk_level": "unknown",
            "summary": "Muse could not check this action.", "guidance": message, "categories": [],
            "mode": mode, "duration_ms": 0, "error": message
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: response) else { return nil }
        var count = UInt32(body.count).littleEndian
        return withUnsafeBytes(of: &count) { Data($0) } + body
    }
}

private final class Lane: Sendable {
    let queue = OperationQueue()
    let slots: DispatchSemaphore

    init(workers: Int, capacity: Int) {
        queue.maxConcurrentOperationCount = workers
        slots = DispatchSemaphore(value: capacity)
    }
}

/// Matches the development host's three independent bounded request lanes.
private final class NativeHost: @unchecked Sendable {
    private static let controlRequests: Set<String> = [
        "status", "present-block", "present-warning", "cancel", "protection-state",
        "chat-context-poll", "chat-context-result", "monitoring-state", "monitoring-control",
        "secret-paste", "target-update", "target-invalidated", "download-command-result", "prediction-update"
    ]
    private let control = Lane(workers: 2, capacity: 16)
    private let analysis = Lane(workers: 4, capacity: 8)
    private let download = Lane(workers: 2, capacity: 4)
    private let socketPath: String
    private let stateLock = NSLock()
    private let outputLock = NSLock()
    private var activeSockets = Set<Int32>()
    private var stopped = false

    init(socketPath: String) { self.socketPath = socketPath }

    private func lane(for request: [String: Any]) -> Lane {
        guard request["version"] as? Int == 1,
              request["mode"] == nil || request["mode"] as? String == "text",
              let type = request["type"] as? String else { return analysis }
        if Self.controlRequests.contains(type) { return control }
        if type == "download-inspect", let item = request["download"] as? [String: Any] {
            if item["phase"] as? String == "metadata" { return control }
            if item["phase"] as? String == "complete" { return download }
        }
        return analysis
    }

    func run(oneShot: Bool) {
        let lanes = [control, analysis, download]
        var cleanEOF = false
        do {
            while !stateLock.withLock({ stopped }) {
                guard let frame = try Frame.read(from: STDIN_FILENO, limit: maxRequestBytes) else {
                    cleanEOF = true
                    break
                }
                submit(frame)
            }
        } catch {
            // Invalid framing has no trustworthy request identifier to reply to.
        }
        if !oneShot || !cleanEOF {
            stop()
            for lane in lanes { lane.queue.cancelAllOperations() }
        }
        for lane in lanes { lane.queue.waitUntilAllOperationsAreFinished() }
    }

    private func submit(_ frame: Frame) {
        let mode = frame.object["mode"] as? String == "vision" ? "vision" : "text"
        guard let id = frame.object["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            send(Frame.failure(id: "", mode: mode, message: "The browser request identifier was not valid."))
            return
        }
        let lane = lane(for: frame.object)
        guard lane.slots.wait(timeout: .now()) == .success else {
            send(Frame.failure(id: id, mode: mode, message: "Muse is busy. Wait for the current check, then retry."))
            return
        }
        let bytes = frame.data
        lane.queue.addOperation { [self] in
            defer { lane.slots.signal() }
            do { send(try forward(bytes, id: id)) }
            catch { send(Frame.failure(id: id, mode: mode, message: error.localizedDescription)) }
        }
    }

    private func forward(_ data: Data, id: String) throws -> Data {
        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8)
        var attributes = stat()
        guard socketPath.hasPrefix("/"), pathBytes.count < MemoryLayout.size(ofValue: address.sun_path),
              lstat(socketPath, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFSOCK,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else { throw HostError(unavailable) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes + [0]) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError(unavailable) }
        let registered = stateLock.withLock {
            guard !stopped else { return false }
            activeSockets.insert(fd)
            return true
        }
        defer {
            stateLock.withLock {
                activeSockets.remove(fd)
                _ = close(fd)
            }
        }
        guard registered else { throw HostError(unavailable) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, !stateLock.withLock({ stopped }) else { throw HostError(unavailable) }
        let response: Frame
        do {
            try Frame.write(data, to: fd)
            guard let frame = try Frame.read(from: fd, limit: maxResponseBytes) else { throw HostError(unavailable) }
            response = frame
        } catch {
            throw HostError(unavailable)
        }
        guard response.object["id"] as? String == id else { throw HostError("Muse Guard returned an unrelated response.") }
        return response.data
    }

    private func send(_ data: Data?) {
        guard let data else { return }
        outputLock.withLock {
            guard !stateLock.withLock({ stopped }) else { return }
            do { try Frame.write(data, to: STDOUT_FILENO) }
            catch { stop() }
        }
    }

    private func stop() {
        stateLock.withLock {
            stopped = true
            // Workers retain ownership of their descriptors until they finish.
            for fd in activeSockets { shutdown(fd, SHUT_RDWR) }
        }
    }
}

@main
private struct MuseGuardHost {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        umask(0o077)
        do {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
            let origin = try extensionOrigin(contents: contents)
            let arguments = Array(CommandLine.arguments.dropFirst())
            let home = FileManager.default.homeDirectoryForCurrentUser
            if arguments == ["--register"] {
                try register(executable: executable, origin: origin, home: home)
                return
            }
            let oneShot = arguments.first == "--one-shot"
            let caller = oneShot ? Array(arguments.dropFirst()) : arguments
            guard caller == [origin] || caller == [String(origin.dropLast())] else {
                throw HostError("This extension is not authorized for Muse Guard.")
            }
            let socketURL = home.appendingPathComponent("Library/Application Support/MuseGuard/BrowserBridge/bridge.sock")
            NativeHost(socketPath: socketURL.path).run(oneShot: oneShot)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func extensionOrigin(contents: URL) throws -> String {
        let manifest = contents.appendingPathComponent("Resources/ChromeExtension/manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, let publicKey = Data(base64Encoded: key), !publicKey.isEmpty else {
            throw HostError("The bundled Muse Guard Chrome extension is missing or invalid. Reinstall Muse Guard.")
        }
        let alphabet = Array("abcdefghijklmnop")
        let id = SHA256.hash(data: publicKey).prefix(16).flatMap { byte in
            [alphabet[Int(byte >> 4)], alphabet[Int(byte & 15)]]
        }
        return "chrome-extension://\(String(id))/"
    }

    private static func register(executable: URL, origin: String, home: URL) throws {
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let destination = directory.appendingPathComponent("\(hostName).json")
        var attributes = stat()
        if lstat(directory.path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_uid == getuid() else {
                throw HostError("Chrome’s native messaging folder is not a directory owned by this user.")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if lstat(destination.path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid() else {
                throw HostError("The existing Muse Guard registration is not a file owned by this user.")
            }
        }
        let manifest: [String: Any] = [
            "name": hostName, "description": "Muse Guard local browser safety bridge",
            "path": executable.path, "type": "stdio", "allowed_origins": [origin]
        ]
        let contents = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let temporary = directory.appendingPathComponent(".muse-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try contents.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, destination.path) == 0 else {
            throw HostError("Could not register Muse Guard in Chrome’s native messaging folder.")
        }
    }
}
