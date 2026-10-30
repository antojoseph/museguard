import AppKit
import Foundation

private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedCount = 0
    private var startedCount = 0
    let release = DispatchSemaphore(value: 0)
    func enqueued() { lock.lock(); queuedCount += 1; lock.unlock() }
    func started() { lock.lock(); startedCount += 1; lock.unlock() }
    var counts: (queued: Int, started: Int) { lock.lock(); defer { lock.unlock() }; return (queuedCount, startedCount) }
}

@main struct ScreenshotCaptureChecks {
    static func main() async throws {
        let probe = CaptureProbe()
        let capture = ScreenshotCapture(operation: { window, _, _ in
            assert(window > 0)
            probe.started()
            if window == 1 { probe.release.wait() }
            return CapturedScreenshot(dataURL: "fixture-window-\(window)")
        }, onQueued: { probe.enqueued() })
        let first = Task { try await capture.captureAsync(windowID: 1) }
        while probe.counts.started < 1 { await Task.yield() }
        let cancelled = Task { try await capture.captureAsync(windowID: 2) }
        while probe.counts.queued < 2 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Queued capture must cancel promptly.") }
        catch is CancellationError {}
        probe.release.signal()
        let firstImage = try await first.value
        assert(firstImage.dataURL == "fixture-window-1")
        // Draining a later request proves the cancelled queue item was passed.
        let finalImage = try await capture.captureAsync(windowID: 3)
        assert(finalImage.dataURL == "fixture-window-3")
        assert(probe.counts.started == 2, "A cancelled queued request must never capture pixels.")
        do { _ = try await capture.captureAsync(windowID: 0); assertionFailure("Null window is never a desktop fallback.") }
        catch ScreenshotCaptureError.captureFailed {}
        assert(probe.counts.started == 2)
        print("PASS: queued screenshots cancel before capture, resume callers promptly and reject null window targets")
    }
}
