import Foundation

private final class StubProtocol: URLProtocol {
    static var payload = Data()
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "127.0.0.1")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ResponseChecks {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let analyzer = LocalRiskAnalyzer(session: URLSession(configuration: config), scheduler: LocalInferenceScheduler())
        let snapshot = ScreenSnapshot(appName: "Test", windowTitle: nil, text: "synthetic")
        let good = "{\"risk_level\":\"high\",\"summary\":\"Lookalike domain\",\"guidance\":\"Close this page\",\"categories\":[\"phishing\"]}"
        func set(_ content: String?, reason: String? = "stop") throws {
            var message: [String: Any] = ["reasoning_content": "This is hidden model reasoning, not the verdict."]
            message["content"] = content ?? NSNull()
            var choice: [String: Any] = ["message": message]
            if let reason { choice["finish_reason"] = reason }
            StubProtocol.payload = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        }
        try set(good)
        let result = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model)
        assert(result.riskLevel == .high)
        let safe = "{\"risk_level\":\"safe\",\"summary\":\"Ordinary documentation page\",\"guidance\":\"Continue browsing\",\"categories\":[\"none\"]}"
        try set(safe, reason: "stop")
        let direct = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model, directAnswer: true)
        assert(direct.riskLevel == .safe, "A completed direct JSON answer must remain valid.")
        // A syntactically complete safe object is insufficient when the server
        // does not confirm normal completion. Never clear an action from it.
        let incomplete: [(String, String?)] = [("missing finish reason", nil),
            ("unknown finish reason", "unexpected"), ("tool-call finish", "tool_calls"),
            ("filtered finish", "content_filter")]
        for (label, reason) in incomplete {
            try set(safe, reason: reason)
            do {
                _ = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model, directAnswer: true)
                fatalError("Accepted \(label)")
            } catch LocalRiskAnalyzerError.invalidResponse { print("PASS rejects \(label)") }
            catch { fatalError("Unexpected error for \(label): \(error)") }
        }
        for (label, content, reason) in [("truncated", good, "length"), ("empty", "", "stop"), ("bad JSON", "safe", "stop"), ("invalid enum", good.replacingOccurrences(of: "high", with: "certain"), "stop"), ("empty summary", good.replacingOccurrences(of: "Lookalike domain", with: ""), "stop")] {
            try set(content, reason: reason)
            do { _ = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model); fatalError("Accepted \(label)") }
            catch { print("PASS rejects \(label)") }
        }
        try set(nil)
        do { _ = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model); fatalError("Accepted reasoning-only answer") }
        catch { print("PASS rejects reasoning-only answer") }
        StubProtocol.status = 503
        do { _ = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model); fatalError("Accepted unavailable server") }
        catch { print("PASS reports unavailable server") }
        print("PASS valid structured response and loopback destination")
    }
}
