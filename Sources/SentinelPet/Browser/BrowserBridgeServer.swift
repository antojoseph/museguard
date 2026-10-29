import Foundation
import Darwin

/// Only a private same-user Unix socket is exposed; there is no listening TCP
/// port or browser CORS endpoint. Every connection carries one bounded frame.
@MainActor
final class BrowserBridgeServer {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MuseGuard/BrowserBridge", isDirectory: true)
    }
    static var socketURL: URL { directory.appendingPathComponent("bridge.sock") }
    private var io: BrowserBridgeIO?
    func start(handler: @escaping @MainActor (BrowserRequest) async -> BrowserResponse) throws {
        guard io == nil else { return }
        io = try BrowserBridgeIO(socketURL: Self.socketURL, handler: handler)
    }
    /// An alternate private path is used only by executable transport checks.
    func start(socketURL: URL, handler: @escaping @MainActor (BrowserRequest) async -> BrowserResponse) throws {
        guard io == nil else { return }
        io = try BrowserBridgeIO(socketURL: socketURL, handler: handler)
    }
    func stop() { io?.stop(); io = nil }
}

// Mutable connection ownership is protected by lock; blocking I/O stays on queue.
private final class BrowserBridgeIO: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.antojoseph.museguard.browser-bridge", qos: .userInitiated, attributes: .concurrent)
    private let handler: @MainActor (BrowserRequest) async -> BrowserResponse
    private var listener: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var clients = Set<Int32>()
    private var stopped = false
    private let socketURL: URL
    private let lockURL: URL

    init(socketURL: URL, handler: @escaping @MainActor (BrowserRequest) async -> BrowserResponse) throws {
        self.socketURL = socketURL; self.lockURL = socketURL.deletingLastPathComponent().appendingPathComponent("bridge.lock")
        self.handler = handler
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw BrowserProtocolError.unavailable }
        guard chmod(directory.path, 0o700) == 0 else { throw BrowserProtocolError.unavailable }
        lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw BrowserProtocolError.unavailable }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1; throw BrowserProtocolError.alreadyRunning
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8)
            let maximum = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count < maximum else { throw BrowserProtocolError.socketPathTooLong }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes + [0]) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            // The lock identifies this server's endpoint. Never remove a file
            // that isn't a same-user socket left by an earlier process.
            var existing = stat()
            if lstat(socketURL.path, &existing) == 0 {
                guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else { throw BrowserProtocolError.unavailable }
                guard unlink(socketURL.path) == 0 else { throw BrowserProtocolError.unavailable }
            }
            socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw BrowserProtocolError.unavailable }
            _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, chmod(socketURL.path, 0o600) == 0,
                  listen(socketFD, 8) == 0, fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else { throw BrowserProtocolError.unavailable }
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAvailable() }
            listener = source; source.resume()
        } catch {
            if socketFD >= 0 { close(socketFD); socketFD = -1 }
            close(lockFD); lockFD = -1
            throw error
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let descriptors = clients
        let listening = socketFD; socketFD = -1
        lock.unlock()
        listener?.cancel(); listener = nil
        if listening >= 0 { shutdown(listening, SHUT_RDWR); close(listening) }
        for fd in descriptors { shutdown(fd, SHUT_RDWR) }
        unlink(socketURL.path)
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
    private func acceptAvailable() {
        while true {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            let fd = accept(socketFD, nil, nil)
            guard fd >= 0 else { lock.unlock(); return }
            guard clients.count < 8 else { lock.unlock(); close(fd); continue }
            clients.insert(fd)
            lock.unlock()
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, 0)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [self] in receive(fd) }
        }
    }
    private func receive(_ fd: Int32) {
        var id = "", mode = "text"
        do {
            let header = try readExactly(fd, count: 4)
            let count = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard count > 0, count <= BrowserRequest.maximumFrameBytes else { throw BrowserProtocolError.frameTooLarge }
            let payload = try readExactly(fd, count: count)
            let raw = try JSONDecoder().decode(BrowserRequest.self, from: payload)
            id = String(raw.id.prefix(128)); mode = raw.mode == "vision" ? "vision" : "text"
            let request = try raw.validated()
            Task { [self] in
                guard self.contains(fd) else { self.finish(fd); return }
                let result = await self.handler(request)
                self.queue.async { [self] in reply(fd, result) }
            }
        } catch { reply(fd, .failure(id: id, mode: mode, message: error.localizedDescription)) }
    }
    private func contains(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }; return !stopped && clients.contains(fd)
    }
    private func reply(_ fd: Int32, _ response: BrowserResponse) {
        defer { finish(fd) }
        guard contains(fd) else { return }
        guard let body = try? JSONEncoder().encode(response), body.count <= 1_048_576 else { return }
        var count = UInt32(body.count).littleEndian
        let frame = withUnsafeBytes(of: &count) { Data($0) } + body
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count-offset)
                if wrote <= 0 { break }; offset += wrote
            }
        }
    }
    private func finish(_ fd: Int32) {
        lock.lock()
        let owned = clients.remove(fd) != nil
        lock.unlock()
        if owned { shutdown(fd, SHUT_RDWR); close(fd) }
    }
    private func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                guard contains(fd) else { throw BrowserProtocolError.unavailable }
                let read = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count-offset)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw BrowserProtocolError.truncatedFrame }
                offset += read
            }
        }
        return result
    }
}
