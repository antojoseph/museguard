import Foundation
import Darwin

private func beginExchange(_ socketURL: URL, _ payload: Data, declaredLength: Int? = nil) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BrowserProtocolError.unavailable }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketURL.path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { close(fd); throw BrowserProtocolError.unavailable }
    var length = UInt32(declaredLength ?? payload.count).littleEndian
    let framed = withUnsafeBytes(of: &length) { Data($0) } + payload
    framed.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let wrote = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
            precondition(wrote > 0); offset += wrote
        }
    }
    return fd
}

private func exchange(_ socketURL: URL, _ payload: Data, declaredLength: Int? = nil) throws -> BrowserResponse {
    let fd = try beginExchange(socketURL, payload, declaredLength: declaredLength)
    defer { close(fd) }
    shutdown(fd, SHUT_WR)
    func read(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count-offset)
                guard received > 0 else { throw BrowserProtocolError.truncatedFrame }
                offset += received
            }
        }
        return result
    }
    let header = try read(4)
    let count = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    guard count <= 1_048_576 else { throw BrowserProtocolError.frameTooLarge }
    return try JSONDecoder().decode(BrowserResponse.self, from: read(count))
}

@main struct BrowserBridgeChecks {
    @MainActor static func main() async throws {
        let page = BrowserRequest.Page(url: "https://person:secret@example.test/login?token=secret#private", title: "Synthetic", text: "Visible text")
        let request = BrowserRequest(id: "one", type: "assess", page: page, action: .init(kind: "submit", url: "https://example.test/submit?key=private", label: "Sign in", method: "post", sensitive: true), purpose: "intent")
        let cleaned = try request.validated()
        assert(cleaned.page?.url == "https://example.test/login")
        assert(cleaned.action?.url == "https://example.test/submit" && cleaned.action?.method == "POST")
        // Match Chrome's actual background descriptor, including empty
        // strings for optional fields rather than only native constructors.
        for kind in ["page", "link"] {
            var wire: [String: Any] = ["version": 1, "id": "chrome-"+kind,
                "type": "assess", "mode": "text",
                "page": ["url": "https://example.test/", "title": "Chrome fixture", "text": "Documentation"],
                "action": ["kind": kind, "url": "https://example.test/docs", "label": "", "method": "", "sensitive": false]]
            wire["purpose"] = kind == "link" ? "intent" : "proactive"
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: wire))
            let chromeMethod = try decoded.validated().action?.method
            assert(chromeMethod == "GET")
            let missing = BrowserRequest(id: "missing-"+kind, type: "assess", page: page,
                action: .init(kind: kind, url: page.url, label: nil, method: nil, sensitive: nil), purpose: kind == "link" ? "intent" : "proactive")
            let missingMethod = try missing.validated().action?.method
            assert(missingMethod == "GET")
        }
        let defaultForm = BrowserRequest(id: "default-form", type: "assess", page: page,
            action: .init(kind: "submit", url: page.url, label: nil, method: nil, sensitive: true), purpose: "intent")
        let defaultMethod = try defaultForm.validated().action?.method
        assert(defaultMethod == "GET")
        _ = try BrowserRequest(id: "status", type: "status").validated()
        for enabled in [true,false] {
            let heartbeat = try BrowserRequest(id: "protection", type: "protection-state", protectionEnabled: enabled).validated()
            let data = try JSONEncoder().encode(heartbeat)
            let wire = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            assert(Set(wire.keys) == Set(["version","id","type","mode","protection_enabled"]))
            assert(wire["protection_enabled"] as? Bool == enabled)
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: data)
            assert(decoded.protectionEnabled == enabled)
        }
        for badBool in ["true",1,NSNull()] as [Any] {
            let wire: [String: Any] = ["version":1,"id":"bad-state","type":"protection-state","mode":"text","protection_enabled":badBool]
            do {
                let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject:wire))
                _ = try decoded.validated()
                fatalError("A non-Boolean protection state was accepted")
            } catch {}
        }
        _ = try BrowserRequest(id: "repeat-high", type: "present-block", assessmentID: "one").validated()
        for purpose in ["proactive", "intent"] {
            let request = try BrowserRequest(id: "background-"+purpose, type: "assess", page: page,
                action: .init(kind: "submit", url: page.url, label: nil, method: "POST", sensitive: true), purpose: purpose).validated()
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(request))
            assert(decoded.purpose == purpose)
        }
        _ = try BrowserRequest(id: "cancel", type: "cancel", assessmentID: "one").validated()
        let response = BrowserResponse(id: "manual", ok: true, decision: "review", riskLevel: "unknown",
            summary: "Synthetic", guidance: "Review this page")
        let responseWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! [String: Any]
        assert(responseWire["action_state"] == nil && responseWire["last_assessment"] == nil && responseWire["completed_assessments"] == nil)
        let diagnostic = BrowserResponse(id: "health", ok: true, decision: "review", riskLevel: "unknown",
            summary: "Connected", guidance: "Ready", modelReady: true,
            lastAssessment: .init(id: "prefetch", kind: "submit", riskLevel: "high", ok: true, completedAt: 1_793_306_700_123),
            completedAssessments: 3)
        let diagnosticData = try JSONEncoder().encode(diagnostic)
        let diagnosticWire = try JSONSerialization.jsonObject(with: diagnosticData) as! [String: Any]
        let metadata = diagnosticWire["last_assessment"] as! [String: Any]
        assert(Set(metadata.keys) == Set(["id", "kind", "risk_level", "ok", "completed_at"]))
        assert(metadata["completed_at"] as? Int64 == 1_793_306_700_123 && diagnosticWire["completed_assessments"] as? Int == 3)
        let decodedDiagnostic = try JSONDecoder().decode(BrowserResponse.self, from: diagnosticData)
        assert(decodedDiagnostic.lastAssessment?.kind == "submit" && decodedDiagnostic.lastAssessment?.ok == true)
        assert(decodedDiagnostic.completedAssessments == 3)
        let tooManyBytes = "a" + String(repeating: "\u{0301}", count: 17_000)
        for invalid in [BrowserRequest(id: "manual-page", type: "assess", page: page),
                        BrowserRequest(id: "retired", type: "decision", assessmentID: "one"),
                        BrowserRequest(id: "retired", type: "finish-checking", assessmentID: "one"),
                        BrowserRequest(id: "retired", type: "notice", page: page, reason: "checking"),
                        BrowserRequest(id: "retired", type: "notice", page: page, reason: "unsupported"),
                        BrowserRequest(id: "retired", type: "notice", page: page, reason: "open_failed"),
                        BrowserRequest(id: "retired", type: "assess", page: page, action: .init(kind: "submit", url: page.url, label: nil, method: "POST", sensitive: true)),
                        BrowserRequest(id: "retired", type: "assess", page: page, action: .init(kind: "link", url: page.url, label: nil, method: "GET", sensitive: false)),
                        BrowserRequest(id: "x", type: "protection-state"),
                        BrowserRequest(id: "x", type: "protection-state", mode: "vision", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", page: page, protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", action: .init(kind:"page",url:nil,label:nil,method:nil,sensitive:nil), protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", screenshot: "private-image", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", assessmentID: "one", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", reason: "checking", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "protection-state", purpose: "proactive", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "status", protectionEnabled: false),
                        BrowserRequest(id: "x", type: "assess", page: page, protectionEnabled: true),
                        BrowserRequest(id: "x", type: "present", assessmentID: "one", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "present-block", assessmentID: "one", protectionEnabled: false),
                        BrowserRequest(id: "x", type: "decision", assessmentID: "one", protectionEnabled: false),
                        BrowserRequest(id: "x", type: "cancel", assessmentID: "one", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "notice", page: page, reason: "checking", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "finish-checking", assessmentID: "one", protectionEnabled: true),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "", text: tooManyBytes), purpose: "proactive"),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "a" + String(repeating: "\u{0301}", count: 700), text: ""), purpose: "proactive"),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "link", url: page.url, label: "a" + String(repeating: "\u{0301}", count: 1_100), method: nil, sensitive: false), purpose: "intent"),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "submit", url: page.url, label: nil, method: "", sensitive: false), purpose: "intent"),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "submit", url: page.url, label: nil, method: "DELETE", sensitive: false), purpose: "intent"),
                        BrowserRequest(id: "x", type: "finish-checking"),
                        BrowserRequest(id: "x", type: "present-block"),
                        BrowserRequest(id: "x", type: "present-block", page: page, assessmentID: "one"),
                        BrowserRequest(id: "x", type: "present-block", assessmentID: "one", purpose: "intent"),
                        BrowserRequest(id: "x", type: "assess", page: page, purpose: "foreground"),
                        BrowserRequest(id: "x", type: "notice", page: page, reason: "checking", purpose: "intent"),
                        BrowserRequest(id: "x", type: "finish-checking", page: page, assessmentID: "one"),
                        BrowserRequest(id: "x", type: "decision"),
                        BrowserRequest(id: "x", type: "cancel", page: page, assessmentID: "one"),
                        BrowserRequest(id: "x", type: "notice", page: page, reason: "arbitrary-message"),
                        BrowserRequest(version: 2, id: "x", type: "status"),
                        BrowserRequest(id: "x", type: "present"),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "file:///secret", title: "", text: ""), purpose: "proactive"),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "", text: String(repeating:"a", count:8001)), purpose: "proactive"),
                        BrowserRequest(id: "x", type: "assess", mode: "vision", page: page, screenshot: "data:image/png;base64,aW52YWxpZA=="),
                        BrowserRequest(id: "x", type: "assess", page: page, screenshot: "unexpected") ] {
            do { _ = try invalid.validated(); fatalError("Invalid request accepted") } catch {}
        }
        let directory = URL(fileURLWithPath: "/tmp/muse-bridge-check-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("bridge.sock")
        let server = BrowserBridgeServer()
        var completionOrder: [String] = []
        var waiting = Set<String>(), cancelled = Set<String>()
        try server.start(socketURL: endpoint) { input in
            if input.id.hasPrefix("cancel-") {
                waiting.insert(input.id)
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch is CancellationError { cancelled.insert(input.id) }
                catch {}
            }
            if input.id == "slow" { try? await Task.sleep(nanoseconds: 200_000_000) }
            completionOrder.append(input.id)
            return BrowserResponse(id: input.id, ok: true, decision: "allow", riskLevel: "safe", summary: "Synthetic test", guidance: "Continue")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.path)
        assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let encoder = JSONEncoder()
        let slow = try encoder.encode(BrowserRequest(id: "slow", type: "status"))
        let fast = try encoder.encode(BrowserRequest(id: "fast", type: "status"))
        async let first = Task.detached { try exchange(endpoint, slow) }.value
        try await Task.sleep(nanoseconds: 40_000_000)
        async let second = Task.detached { try exchange(endpoint, fast) }.value
        let values = try await [first,second]
        assert(values.map(\.id) == ["slow","fast"] && completionOrder == ["fast","slow"])
        let bad = try await Task.detached { try exchange(endpoint, Data("{}".utf8), declaredLength: 8) }.value
        assert(!bad.ok && bad.decision == "review" && bad.riskLevel == "unknown")
        let huge = try await Task.detached { try exchange(endpoint, Data(), declaredLength: BrowserRequest.maximumFrameBytes+1) }.value
        assert(!huge.ok && huge.decision == "review")
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            assert(condition(), "Expected transport cancellation within one second")
        }
        let disconnected = try beginExchange(endpoint, encoder.encode(BrowserRequest(id: "cancel-disconnect", type: "status")))
        try await waitFor { waiting.contains("cancel-disconnect") }
        let disconnectTime = Date()
        close(disconnected)
        try await waitFor { cancelled.contains("cancel-disconnect") }
        assert(Date().timeIntervalSince(disconnectTime) < 1)
        let stopping = try beginExchange(endpoint, encoder.encode(BrowserRequest(id: "cancel-stop", type: "status")))
        try await waitFor { waiting.contains("cancel-stop") }
        let stopTime = Date()
        server.stop()
        try await waitFor { cancelled.contains("cancel-stop") }
        assert(Date().timeIntervalSince(stopTime) < 1)
        close(stopping)
        assert(!FileManager.default.fileExists(atPath: endpoint.path))
        print("PASS browser URL redaction, retired manual/image routes, UTF-8 limits, private socket permissions, concurrent correlated half-closed replies, truncation/oversize rejection, peer-disconnect cancellation and shutdown cancellation")
    }
}
