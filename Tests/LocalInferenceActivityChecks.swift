import Foundation

private actor ActivityRecorder {
    private var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
    func snapshot() -> [Bool] { values }
}

private actor OrderRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor OperationGate {
    private(set) var started = false
    private(set) var cancelled = false
    private var released = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func noteCancellation() { cancelled = true }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

private func observe(_ scheduler: LocalInferenceScheduler) async -> (Task<Void,Never>,ActivityRecorder) {
    let stream = await scheduler.activityUpdates(), recorder = ActivityRecorder()
    let receiver = Task {
        for await value in stream { await recorder.append(value) }
    }
    return (receiver,recorder)
}

private func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await predicate()) {
        assert(Date() < deadline,"Controlled scheduler activity did not reach the expected state.")
        try await Task.sleep(nanoseconds:2_000_000)
    }
}

private enum SyntheticFailure: Error { case model }

@main struct LocalInferenceActivityChecks {
    static func main() async throws {
        // Current state is replayed to each observer; terminating one observer
        // does not affect actual work or the remaining subscribers.
        let scheduler = LocalInferenceScheduler()
        let (firstObserver,first) = await observe(scheduler)
        let (secondObserver,second) = await observe(scheduler)
        try await eventually { let a = await first.snapshot(), b = await second.snapshot(); return a == [false] && b == [false] }
        let gate = OperationGate()
        let work = Task { try await scheduler.run(priority:.interactive) { await gate.wait(); return "finished" } }
        try await eventually { let started = await gate.started, a = await first.snapshot(), b = await second.snapshot(); return started && a == [false,true] && b == [false,true] }
        let (lateObserver,late) = await observe(scheduler)
        try await eventually { await late.snapshot() == [true] }
        secondObserver.cancel(); await secondObserver.value
        await gate.release()
        let completed = try await work.value
        assert(completed == "finished")
        try await eventually { let a = await first.snapshot(), b = await late.snapshot(); return a == [false,true,false] && b == [true,false] }
        let stoppedObserver = await second.snapshot()
        assert(stoppedObserver == [false,true],"An observer that terminated must not receive later work updates.")
        firstObserver.cancel(); lateObserver.cancel()
        await firstObserver.value; await lateObserver.value

        // Keep one operation alive while a queued request is cancelled. The
        // queued request itself must never generate work or clear active work.
        let queuedScheduler = LocalInferenceScheduler()
        let (queueObserver,queueStates) = await observe(queuedScheduler)
        try await eventually { await queueStates.snapshot() == [false] }
        let heldGate = OperationGate(), neverRunGate = OperationGate()
        let held = Task { try await queuedScheduler.run(priority:.interactive) { await heldGate.wait(); return "held" } }
        try await eventually { let started = await heldGate.started, states = await queueStates.snapshot(); return started && states == [false,true] }
        let queued = Task { try await queuedScheduler.run(priority:.background) { await neverRunGate.wait(); return "unexpected" } }
        // The active operation is deliberately held, so the pending caller
        // cannot reach its closure even if the scheduler accepts it promptly.
        try await Task.sleep(nanoseconds:10_000_000)
        queued.cancel()
        do { _ = try await queued.value; assertionFailure("Cancelled queued work completed") }
        catch is CancellationError {} catch { assertionFailure("Unexpected queued cancellation: \(error)") }
        let pendingStarted = await neverRunGate.started, whileHeld = await queueStates.snapshot()
        assert(!pendingStarted && whileHeld == [false,true])
        await heldGate.release(); _ = try await held.value
        try await eventually { await queueStates.snapshot() == [false,true,false] }
        queueObserver.cancel(); await queueObserver.value

        // A priority handoff preserves active state until the successor ends.
        // Cancellation is observed by the real operation but cleanup is held,
        // proving that a cancel request alone does not claim the slot is idle.
        let handoffScheduler = LocalInferenceScheduler()
        let (handoffObserver,handoffStates) = await observe(handoffScheduler)
        try await eventually { await handoffStates.snapshot() == [false] }
        let backgroundGate = OperationGate(), foregroundGate = OperationGate()
        let background = Task {
            try await handoffScheduler.run(priority:.background) {
                await withTaskCancellationHandler(operation: { await backgroundGate.wait() },
                    onCancel: { Task { await backgroundGate.noteCancellation() } })
                return "background"
            }
        }
        try await eventually { let started = await backgroundGate.started, states = await handoffStates.snapshot(); return started && states == [false,true] }
        let foreground = Task { try await handoffScheduler.run(priority:.interactive) { await foregroundGate.wait(); return "foreground" } }
        try await eventually { await backgroundGate.cancelled }
        let beforeCleanup = await handoffStates.snapshot(), successorStarted = await foregroundGate.started
        assert(beforeCleanup == [false,true] && !successorStarted)
        await backgroundGate.release()
        do { _ = try await background.value; assertionFailure("Preempted work completed") }
        catch is CancellationError {} catch { assertionFailure("Unexpected preemption: \(error)") }
        try await eventually { await foregroundGate.started }
        let duringHandoff = await handoffStates.snapshot()
        assert(duringHandoff == [false,true],"The working cue cannot blink off while a successor owns the model slot.")
        await foregroundGate.release(); _ = try await foreground.value
        try await eventually { await handoffStates.snapshot() == [false,true,false] }
        handoffObserver.cancel(); await handoffObserver.value

        // New interactive work must not cancel a current chat. Once that chat
        // finishes, queued interactive work runs FIFO ahead of background work.
        let priorityScheduler = LocalInferenceScheduler(), order = OrderRecorder()
        let currentGate = OperationGate()
        let current = Task {
            try await priorityScheduler.run(priority:.interactive) {
                await order.append("current")
                await withTaskCancellationHandler(operation: { await currentGate.wait() },
                    onCancel: { Task { await currentGate.noteCancellation() } })
                return "current"
            }
        }
        try await eventually { await currentGate.started }
        let lower = Task {
            try await priorityScheduler.run(priority:.background) {
                await order.append("background"); return "background"
            }
        }
        try await eventually { await priorityScheduler.pendingOperationCount() == 1 }
        let firstInteractive = Task {
            try await priorityScheduler.run(priority:.interactive) {
                await order.append("first-interactive"); return "first"
            }
        }
        try await eventually { await priorityScheduler.pendingOperationCount() == 2 }
        let secondInteractive = Task {
            try await priorityScheduler.run(priority:.interactive) {
                await order.append("second-interactive"); return "second"
            }
        }
        try await eventually { await priorityScheduler.pendingOperationCount() == 3 }
        let currentWasCancelled = await currentGate.cancelled, beforeRelease = await order.snapshot()
        assert(!currentWasCancelled && beforeRelease == ["current"])
        await currentGate.release()
        _ = try await current.value
        _ = try await firstInteractive.value
        _ = try await secondInteractive.value
        _ = try await lower.value
        let completionOrder = await order.snapshot()
        assert(completionOrder == ["current","first-interactive","second-interactive","background"])

        let failureScheduler = LocalInferenceScheduler()
        let (failureObserver,failureStates) = await observe(failureScheduler)
        try await eventually { await failureStates.snapshot() == [false] }
        let errorGate = OperationGate()
        let failing = Task {
            try await failureScheduler.run(priority:.interactive) { await errorGate.wait(); throw SyntheticFailure.model }
        }
        try await eventually { let started = await errorGate.started, states = await failureStates.snapshot(); return started && states == [false,true] }
        await errorGate.release()
        do { _ = try await failing.value; assertionFailure("Failing model operation succeeded") }
        catch SyntheticFailure.model {} catch { assertionFailure("Unexpected model failure: \(error)") }
        try await eventually { await failureStates.snapshot() == [false,true,false] }
        failureObserver.cancel(); await failureObserver.value

        let cancellationScheduler = LocalInferenceScheduler()
        let (cancelObserver,cancelStates) = await observe(cancellationScheduler)
        try await eventually { await cancelStates.snapshot() == [false] }
        let cancelGate = OperationGate()
        let cancelled = Task {
            try await cancellationScheduler.run(priority:.interactive) {
                await withTaskCancellationHandler(operation: { await cancelGate.wait() },
                    onCancel: { Task { await cancelGate.noteCancellation() } })
                return "cancelled"
            }
        }
        try await eventually { let started = await cancelGate.started, states = await cancelStates.snapshot(); return started && states == [false,true] }
        cancelled.cancel(); try await eventually { await cancelGate.cancelled }
        let cancelledButCleaningUp = await cancelStates.snapshot()
        assert(cancelledButCleaningUp == [false,true])
        await cancelGate.release()
        do { _ = try await cancelled.value; assertionFailure("Cancelled operation completed") }
        catch is CancellationError {} catch { assertionFailure("Unexpected active cancellation: \(error)") }
        try await eventually { await cancelStates.snapshot() == [false,true,false] }
        cancelObserver.cancel(); await cancelObserver.value

        // A caller already cancelled before run() cannot produce a true cue.
        let unusedScheduler = LocalInferenceScheduler()
        let (unusedObserver,unusedStates) = await observe(unusedScheduler)
        try await eventually { await unusedStates.snapshot() == [false] }
        let beforeRun = OperationGate()
        let unused = Task {
            await beforeRun.wait()
            return try await unusedScheduler.run(priority:.interactive) { "unexpected" }
        }
        try await eventually { await beforeRun.started }
        unused.cancel(); await beforeRun.release()
        do { _ = try await unused.value; assertionFailure("Already-cancelled caller ran work") }
        catch is CancellationError {} catch { assertionFailure("Unexpected early cancellation: \(error)") }
        let unusedSnapshot = await unusedStates.snapshot()
        assert(unusedSnapshot == [false])
        unusedObserver.cancel(); await unusedObserver.value

        // A delayed UI must receive the latest idle state, never a buffered
        // historical true from a model operation that already ended.
        let newestScheduler = LocalInferenceScheduler()
        let unconsumed = await newestScheduler.activityUpdates()
        _ = try await newestScheduler.run(priority:.interactive) { "quick completion" }
        var iterator = unconsumed.makeAsyncIterator()
        let latest = await iterator.next()
        assert(latest == false)
        print("PASS: actual inference activity, idle/late replay, queued cancellation, continuous priority handoff, interactive FIFO before background work, error cleanup and newest-state buffering")
    }
}
