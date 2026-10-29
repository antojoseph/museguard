import Foundation
import Darwin
import ImageIO
import CoreGraphics

private func exchange(_ socketURL: URL, _ payload: Data, declaredLength: Int? = nil) throws -> BrowserResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BrowserProtocolError.unavailable }
    defer { close(fd) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketURL.path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw BrowserProtocolError.unavailable }
    var length = UInt32(declaredLength ?? payload.count).littleEndian
    let framed = withUnsafeBytes(of: &length) { Data($0) } + payload
    framed.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let wrote = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
            precondition(wrote > 0); offset += wrote
        }
    }
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
        let request = BrowserRequest(id: "one", type: "assess", page: page, action: .init(kind: "submit", url: "https://example.test/submit?key=private", label: "Sign in", method: "post", sensitive: true))
        let cleaned = try request.validated()
        assert(cleaned.page?.url == "https://example.test/login")
        assert(cleaned.action?.url == "https://example.test/submit" && cleaned.action?.method == "POST")
        // Match Chrome's actual background descriptor, including empty
        // strings for optional fields rather than only native constructors.
        for kind in ["page", "link"] {
            let wire: [String: Any] = ["version": 1, "id": "chrome-"+kind,
                "type": "assess", "mode": "text",
                "page": ["url": "https://example.test/", "title": "Chrome fixture", "text": "Documentation"],
                "action": ["kind": kind, "url": "https://example.test/docs", "label": "", "method": "", "sensitive": false]]
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: wire))
            let chromeMethod = try decoded.validated().action?.method
            assert(chromeMethod == "GET")
            let missing = BrowserRequest(id: "missing-"+kind, type: "assess", page: page,
                action: .init(kind: kind, url: page.url, label: nil, method: nil, sensitive: nil))
            let missingMethod = try missing.validated().action?.method
            assert(missingMethod == "GET")
        }
        let defaultForm = BrowserRequest(id: "default-form", type: "assess", page: page,
            action: .init(kind: "submit", url: page.url, label: nil, method: nil, sensitive: true))
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
        _ = try BrowserRequest(id: "present", type: "present", assessmentID: "one").validated()
        _ = try BrowserRequest(id: "repeat-high", type: "present-block", assessmentID: "one").validated()
        for purpose in ["proactive", "intent"] {
            let request = try BrowserRequest(id: "background-"+purpose, type: "assess", page: page,
                action: .init(kind: "submit", url: page.url, label: nil, method: "POST", sensitive: true), purpose: purpose).validated()
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(request))
            assert(decoded.purpose == purpose)
        }
        _ = try BrowserRequest(id: "decision", type: "decision", assessmentID: "one").validated()
        _ = try BrowserRequest(id: "cancel", type: "cancel", assessmentID: "one").validated()
        _ = try BrowserRequest(id: "finish", type: "finish-checking", assessmentID: "one").validated()
        let checking = try BrowserRequest(id: "checking", type: "notice", page: page,
            action: .init(kind: "page", url: page.url, label: nil, method: nil, sensitive: nil), reason: "checking").validated()
        assert(checking.reason == "checking" && checking.page?.url == "https://example.test/login")
        for (kind, method) in [("link", "GET"), ("submit", "POST")] {
            let actionChecking = try BrowserRequest(id: "checking-"+kind, type: "notice", page: page,
                action: .init(kind: kind, url: page.url, label: nil, method: method, sensitive: true), reason: "checking").validated()
            assert(actionChecking.action?.kind == kind && actionChecking.action?.method == method)
        }
        let stateResponse = BrowserResponse(id: "decision", ok: true, decision: "review", riskLevel: "unknown",
            summary: "Synthetic", guidance: "Stay", actionState: "pending")
        let stateWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stateResponse)) as! [String: Any]
        assert(stateWire["action_state"] as? String == "pending")
        assert(stateWire["last_assessment"] == nil && stateWire["completed_assessments"] == nil)
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
        // This is a complete 1x1 RGBA PNG, not just its file signature.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP439DwHwAHgAL/OfPOjwAAAABJRU5ErkJggg==")!
        func imageRequest(_ data: Data, mime: String = "png") -> BrowserRequest {
            BrowserRequest(id: "image", type: "assess", mode: "vision", page: page,
                screenshot: "data:image/\(mime);base64," + data.base64EncodedString())
        }
        _ = try imageRequest(png).validated()
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        assert(CGImageDestinationFinalize(destination))
        _ = try imageRequest(jpeg as Data, mime: "jpeg").validated()
        func oversizedPNG(width: UInt32, height: UInt32) -> Data {
            var bytes = [UInt8](png)
            for (offset, value) in [(16,width),(20,height)] {
                for n in 0..<4 { bytes[offset+n] = UInt8((value >> ((3-n)*8)) & 255) }
            }
            var crc: UInt32 = 0xffffffff
            for byte in bytes[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            crc ^= 0xffffffff
            for n in 0..<4 { bytes[29+n] = UInt8((crc >> ((3-n)*8)) & 255) }
            return Data(bytes)
        }
        let tooManyBytes = "a" + String(repeating: "\u{0301}", count: 17_000)
        for invalid in [imageRequest(oversizedPNG(width: 4_097, height: 1)),
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
                        imageRequest(oversizedPNG(width: 4_096, height: 2_049)),
                        imageRequest(Data([137,80,78,71,13,10,26,10])),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "", text: tooManyBytes)),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "a" + String(repeating: "\u{0301}", count: 700), text: "")),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "link", url: page.url, label: "a" + String(repeating: "\u{0301}", count: 1_100), method: nil, sensitive: false)),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "submit", url: page.url, label: nil, method: "", sensitive: false)),
                        BrowserRequest(id: "x", type: "assess", page: page, action: .init(kind: "submit", url: page.url, label: nil, method: "DELETE", sensitive: false)),
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
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "file:///secret", title: "", text: "")),
                        BrowserRequest(id: "x", type: "assess", page: .init(url: "https://example.test", title: "", text: String(repeating:"a", count:8001))),
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
        try server.start(socketURL: endpoint) { input in
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
        server.stop()
        assert(!FileManager.default.fileExists(atPath: endpoint.path))
        print("PASS browser URL redaction, request/image validation, UTF-8 limits and bounded image dimensions, private socket permissions, concurrent correlated replies, truncation/oversize rejection and shutdown")
    }
}
