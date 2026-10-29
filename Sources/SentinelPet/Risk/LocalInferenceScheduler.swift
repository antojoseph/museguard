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
    }
    enum SchedulerError: LocalizedError {
        case busy
        var errorDescription: String? { "The local model is busy. This action has not been cleared; try again." }
    }
}
