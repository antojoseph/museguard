import Foundation

private final class TestClock {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: TimeInterval) { lock.lock(); value = next; lock.unlock() }
}
private actor Gate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await predicate()) {
        assert(Date() < deadline,"Scheduler state did not arrive")
        try await Task.sleep(nanoseconds:1_000_000)
    }
}
private enum SyntheticFailure: Error { case model }

@main struct InferenceMetricsChecks {
    static func main() async throws {
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("inference.json")
        let scheduler = LocalInferenceScheduler(metricsURL:file,now:{ clock.read() })
        let gate = Gate()
        let first = Task {
            try await scheduler.runMeasured(priority:.interactive,kind:.chat) { id in
                await scheduler.recordResponse(id:id,timing:.init(requestMilliseconds:80,firstVisibleMilliseconds:20,
                    promptTokens:20,generatedTokens:10,cachedTokens:15,promptMilliseconds:10,
                    generationMilliseconds:60,tokensPerSecond:25,reasoningCharacters:30))
                await gate.wait()
                return "PRIVATE_ANSWER_DO_NOT_LOG"
            }
        }
        try await eventually { await gate.started }
        clock.set(1)
        let second = Task { try await scheduler.runMeasured(priority:.background,kind:.risk) { _ in "second" } }
        try await eventually { await scheduler.pendingOperationCount() == 1 }
        clock.set(2)
        let cancelled = Task { try await scheduler.runMeasured(priority:.background,kind:.vision) { _ in "must never run" } }
        try await eventually { await scheduler.pendingOperationCount() == 2 }
        clock.set(3); cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Cancelled queued operation completed") }
        catch is CancellationError { }
        clock.set(4); await gate.release()
        _ = try await first.value; _ = try await second.value
        let values = await scheduler.recentMetrics()
        assert(values.count == 3)
        let chat = values.first { $0.kind == .chat }!, risk = values.first { $0.kind == .risk }!
        let vision = values.first { $0.kind == .vision }!
        assert(chat.queueMilliseconds == 0 && chat.workMilliseconds == 4000)
        assert(risk.queueMilliseconds == 3000 && risk.workMilliseconds == 0)
        assert(vision.outcome == "cancelled" && vision.queueMilliseconds == 1000 && vision.workMilliseconds == 0)
        assert(chat.response?.firstVisibleMilliseconds == 20 && chat.response?.tokensPerSecond == 25)
        await scheduler.recordResponse(id:chat.id,timing:.init(requestMilliseconds:999))
        let unchanged = await scheduler.recentMetrics()
        assert(unchanged.first { $0.kind == .chat }!.response == chat.response,"Late metadata must not attach to a completed or different job")
        await scheduler.flushMetrics()
        let wire = try Data(contentsOf:file), text = String(data:wire,encoding:.utf8)!
        assert(!text.contains("PRIVATE_ANSWER") && !text.contains("must never run"))
        let decoded = try JSONDecoder.withISO8601().decode([LocalInferenceScheduler.RunMetric].self,from:wire)
        assert(decoded.count == 3)
        let filePermissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! Int
        let folderPermissions = try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as! Int
        assert(filePermissions & 0o777 == 0o600 && folderPermissions & 0o777 == 0o700)

        let failures = LocalInferenceScheduler()
        do { _ = try await failures.runMeasured(priority:.interactive,kind:.chat) { _ in throw SyntheticFailure.model } }
        catch SyntheticFailure.model { }
        let failed = await failures.recentMetrics()
        assert(failed.count == 1 && failed[0].outcome == "failed")
        for _ in 0..<135 { _ = try await failures.run(priority:.background) { "bounded" } }
        let bounded = await failures.recentMetrics()
        assert(bounded.count == 128 && bounded.allSatisfy { $0.outcome == "completed" })

        // A queue full of routine scans must not reject a real user request.
        let saturated = LocalInferenceScheduler(), heldGate = Gate()
        let held = Task { try await saturated.run(priority:.interactive) { await heldGate.wait(); return "held" } }
        try await eventually { await heldGate.started }
        var queued: [Task<String,Error>] = []
        for _ in 0..<8 { queued.append(Task { try await saturated.run(priority:.background) { "background" } }) }
        try await eventually { await saturated.pendingOperationCount() == 8 }
        let important = Task { try await saturated.runMeasured(priority:.interactive,kind:.chat) { _ in "user" } }
        try await eventually { let records = await saturated.recentMetrics(); return records.contains { $0.outcome == "cancelled" } }
        await heldGate.release(); _ = try await held.value
        let importantAnswer = try await important.value
        assert(importantAnswer == "user")
        var cancellations = 0
        for task in queued { do { _ = try await task.value } catch is CancellationError { cancellations += 1 } }
        assert(cancellations == 1)
        print("PASS: separate queue/work/server timing, bounded private metadata, cancellation/error correlation, private diagnostics and saturated-queue priority")
    }
}
private extension JSONDecoder {
    static func withISO8601() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
