import Foundation

/// One local model slot. Explicit checks take precedence over ambient scans,
/// and cancelled work cannot leave an unbounded inference backlog.
actor LocalInferenceScheduler {
    static let shared = LocalInferenceScheduler()
    enum Priority: Int { case background, interactive, browserAction }
    private struct Job {
        let id: UUID
        let priority: Priority
        let operation: () async throws -> String
        let continuation: CheckedContinuation<String, Error>
    }
    private var waiting: [Job] = []
    private var active: Job?
    private var activeTask: Task<Void, Never>?
    private var isWorking = false
    private var activityObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]

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
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard waiting.count < 8 else {
                    continuation.resume(throwing: SchedulerError.busy)
                    return
                }
                waiting.append(Job(id: id, priority: priority, operation: operation, continuation: continuation))
                if let active, active.priority.rawValue < priority.rawValue {
                    activeTask?.cancel()
                }
                startNext()
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if active?.id == id { activeTask?.cancel() }
    }
    private func startNext() {
        guard active == nil, !waiting.isEmpty else { return }
        let priority = waiting.map { $0.priority.rawValue }.max()!
        let index = waiting.firstIndex { $0.priority.rawValue == priority }!
        let job = waiting.remove(at: index)
        active = job
        activeTask = Task {
            let result: Result<String, Error>
            do {
                try Task.checkCancellation()
                setWorking(true)
                let value = try await job.operation()
                try Task.checkCancellation()
                result = .success(value)
            } catch { result = .failure(error) }
            finish(job.id, result: result)
        }
    }
    private func finish(_ id: UUID, result: Result<String, Error>) {
        guard let job = active, job.id == id else { return }
        active = nil; activeTask = nil
        job.continuation.resume(with: result)
        startNext()
        if active == nil { setWorking(false) }
    }
    enum SchedulerError: LocalizedError {
        case busy
        var errorDescription: String? { "The local model is busy. This action has not been cleared; try again." }
    }
}
