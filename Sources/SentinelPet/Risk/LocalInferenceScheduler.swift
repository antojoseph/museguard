import Foundation

/// One local model slot. Explicit checks take precedence over ambient scans,
/// and cancelled work cannot leave an unbounded inference backlog.
actor LocalInferenceScheduler {
    static let shared = LocalInferenceScheduler(metricsURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MuseGuard/Diagnostics/inference-metrics.json"))
    enum Priority: Int { case background, interactive }
    enum OperationKind: String, Codable { case chat, risk, vision, other }
    /// Metadata only. Never retain prompts, page titles, URLs, answers or keys.
    struct ResponseTiming: Codable, Equatable {
        var requestMilliseconds: Double? = nil
        var firstVisibleMilliseconds: Double? = nil
        var promptTokens: Int? = nil
        var generatedTokens: Int? = nil
        var cachedTokens: Int? = nil
        var promptMilliseconds: Double? = nil
        var generationMilliseconds: Double? = nil
        var tokensPerSecond: Double? = nil
        var reasoningCharacters: Int? = nil
        var visibleCharacters: Int? = nil
    }
    struct RunMetric: Codable {
        let id: UUID
        let kind: OperationKind
        let priority: String
        let enqueuedAt: Date
        let queueMilliseconds: Double
        let workMilliseconds: Double
        let outcome: String
        let response: ResponseTiming?
    }
    private struct Job {
        let id: UUID
        let priority: Priority
        let kind: OperationKind
        let enqueuedAt: Date
        let queuedUptime: TimeInterval
        let operation: (UUID) async throws -> String
        let continuation: CheckedContinuation<String, Error>
    }
    private var waiting: [Job] = []
    private var active: Job?
    private var activeTask: Task<Void, Never>?
    private var isWorking = false
    private var activityObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private let metricsURL: URL?
    private let now: () -> TimeInterval
    private var metrics: [RunMetric] = []
    private var activeStarted: TimeInterval?
    private var activeResponse: ResponseTiming?
    private var metricsWrite: Task<Void,Never>?

    init(metricsURL: URL? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.metricsURL = metricsURL
        self.now = now
    }

    func recentMetrics() -> [RunMetric] { metrics }
    func pendingOperationCount() -> Int { waiting.count }
    func recordResponse(id: UUID, timing: ResponseTiming) {
        guard active?.id == id else { return }
        activeResponse = timing
    }
    func flushMetrics() {
        metricsWrite?.cancel(); metricsWrite = nil
        persistMetrics()
    }

    private func record(_ job: Job, started: TimeInterval?, outcome: String, response: ResponseTiming? = nil) {
        let ended = now(), began = started ?? ended
        metrics.append(RunMetric(id:job.id,kind:job.kind,priority:String(describing:job.priority),
            enqueuedAt:job.enqueuedAt,queueMilliseconds:max(0,began-job.queuedUptime)*1000,
            workMilliseconds:started == nil ? 0 : max(0,ended-began)*1000,outcome:outcome,response:response))
        if metrics.count > 128 { metrics.removeFirst(metrics.count-128) }
        guard metricsURL != nil, metricsWrite == nil else { return }
        metricsWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds:250_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistMetrics()
        }
    }
    private func persistMetrics() {
        metricsWrite = nil
        guard let metricsURL else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metrics)
            try FileManager.default.createDirectory(at:metricsURL.deletingLastPathComponent(),withIntermediateDirectories:true,
                attributes:[.posixPermissions:0o700])
            try data.write(to:metricsURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:metricsURL.path)
        } catch { /* Diagnostics must never prevent or retry inference. */ }
    }

    /// Observe actual slot work, including the current state for late viewers.
    /// A queued request does not start activity, and a consecutive handoff does
    /// not briefly clear it between two model operations.
    func activityUpdates() -> AsyncStream<Bool> {
        let id = UUID()
        var captured: AsyncStream<Bool>.Continuation?
        let stream = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        guard let continuation = captured else { return stream }
        activityObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityObserver(id) }
        }
        continuation.yield(isWorking)
        return stream
    }
    private func removeActivityObserver(_ id: UUID) { activityObservers.removeValue(forKey: id) }
    private func setWorking(_ working: Bool) {
        guard working != isWorking else { return }
        isWorking = working
        for continuation in activityObservers.values { continuation.yield(working) }
    }

    func run(priority: Priority, operation: @escaping () async throws -> String) async throws -> String {
        try await runMeasured(priority:priority,kind:.other) { _ in try await operation() }
    }
    func runMeasured(priority: Priority, kind: OperationKind, operation: @escaping (UUID) async throws -> String) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if waiting.count >= 8 {
                    if let lowest = waiting.map({ $0.priority.rawValue }).min(), lowest < priority.rawValue,
                       let victimIndex = waiting.firstIndex(where:{ $0.priority.rawValue == lowest }) {
                        let victim = waiting.remove(at:victimIndex)
                        record(victim,started:nil,outcome:"cancelled")
                        victim.continuation.resume(throwing:CancellationError())
                    } else {
                        continuation.resume(throwing:SchedulerError.busy)
                        return
                    }
                }
                waiting.append(Job(id:id,priority:priority,kind:kind,enqueuedAt:Date(),queuedUptime:now(),
                    operation:operation,continuation:continuation))
                if let active, active.priority.rawValue < priority.rawValue {
                    activeTask?.cancel()
                }
                startNext()
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            let job = waiting.remove(at:index)
            record(job,started:nil,outcome:"cancelled")
            job.continuation.resume(throwing:CancellationError())
        } else if active?.id == id { activeTask?.cancel() }
    }
    private func startNext() {
        guard active == nil, !waiting.isEmpty else { return }
        let priority = waiting.map { $0.priority.rawValue }.max()!
        let index = waiting.firstIndex { $0.priority.rawValue == priority }!
        let job = waiting.remove(at: index)
        active = job
        activeStarted = now(); activeResponse = nil
        activeTask = Task {
            let result: Result<String, Error>
            do {
                try Task.checkCancellation()
                setWorking(true)
                let value = try await job.operation(job.id)
                try Task.checkCancellation()
                result = .success(value)
            } catch { result = .failure(error) }
            finish(job.id, result: result)
        }
    }
    private func finish(_ id: UUID, result: Result<String, Error>) {
        guard let job = active, job.id == id else { return }
        let outcome: String
        switch result {
        case .success: outcome = "completed"
        case .failure(let error): outcome = error is CancellationError || activeTask?.isCancelled == true ? "cancelled" : "failed"
        }
        record(job,started:activeStarted,outcome:outcome,response:activeResponse)
        active = nil; activeTask = nil
        activeStarted = nil; activeResponse = nil
        job.continuation.resume(with: result)
        startNext()
        if active == nil { setWorking(false) }
    }
    enum SchedulerError: LocalizedError {
        case busy
        var errorDescription: String? { "The local model is busy. This action has not been cleared; try again." }
    }
}
