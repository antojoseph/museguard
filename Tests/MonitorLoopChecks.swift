import Foundation

private enum FixtureError: Error { case failed }

@MainActor private final class MonitorFixture {
    var source = ScreenSourceIdentity(processID: 7, bundleID: "test.editor", windowID: 23, windowTitle: "Guide", appName: "Editor")
    var current: ScreenSourceIdentity?
    var snapshot: ScreenSnapshot?
    var covered = false
    var clock = Date(timeIntervalSince1970: 2_000_000_000)
    var captureCount = 0
    var analyzeCount = 0
    var textReads = 0
    var image = "same-window-image"
    var fail = false
    var analyzeGate: CheckedContinuation<Void, Never>?
    var blockAnalysis = false
    var statuses: [MonitorLoopStatus] = []
    var outputs: [Bool] = []
    var errors = 0
    var images: [String?] = []
    lazy var loop = MonitorLoop(dependencies: .init(
        focusedSource: { [unowned self] in source },
        readText: { [unowned self] _ in textReads += 1; return snapshot },
        isCurrent: { [unowned self] value in (current ?? source) == value },
        captureWindow: { [unowned self] value in
            assert(value.windowID == source.windowID && value.windowID != nil)
            captureCount += 1
            return CapturedScreenshot(dataURL: image)
        },
        analyze: { [unowned self] _, image, _ in
            analyzeCount += 1; images.append(image)
            if blockAnalysis { await withCheckedContinuation { analyzeGate = $0 } }
            if fail { throw FixtureError.failed }
            return RiskVerdict(riskLevel: .safe, summary: "Read guide", guidance: "No concern", categories: [])
        },
        chromeCoverage: { [unowned self] _ in covered },
        now: { [unowned self] in clock }))

    func text(_ text: String = "This is a useful guide with substantial readable document text, rather than toolbar labels.") {
        snapshot = ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle, text: text,
            evidence: .visibleText(text), source: source)
    }
    func visual() {
        snapshot = ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle,
            text: "Canvas", evidence: ContextEvidence(visualElements: 1), source: source)
    }
    func sample() async {
        await loop.sampleOnce(model: "fixture", onStatus: { [unowned self] in statuses.append($0) },
            onVerdict: { [unowned self] _, _, image in outputs.append(image) },
            onError: { [unowned self] _, _ in errors += 1 })
    }
    func release() { analyzeGate?.resume(); analyzeGate = nil }
}

@main struct MonitorLoopChecks {
    @MainActor static func main() async {
        // Ordinary readable documents never capture/encode an image. Cached
        // text avoids both capture and inference on every later sample.
        let text = MonitorFixture(); text.text()
        await text.sample(); await text.sample()
        assert(text.captureCount == 0 && text.analyzeCount == 1 && text.outputs == [false])
        assert(text.loop.diagnostics.textAnalyses == 1 && text.loop.diagnostics.duplicateSkips == 1)
        text.text("This GUIDE contains case-sensitive account IDs AbCd and other readable document text.")
        await text.sample()
        assert(text.analyzeCount == 2 && text.captureCount == 0)
        text.text("This GUIDE contains case-sensitive account IDs abcd and other readable document text.")
        await text.sample()
        assert(text.analyzeCount == 3, "Case changes may change meaning and must not be normalized away.")

        // A canvas gets only its positively identified window. Motion cannot
        // trigger image capture before the cooldown, and identical images do
        // not invoke the model again after a later comparison capture.
        let visual = MonitorFixture(); visual.visual()
        await visual.sample(); await visual.sample()
        assert(visual.captureCount == 2 && visual.analyzeCount == 1 && visual.outputs == [true])
        assert(visual.loop.diagnostics.windowCaptures == 2 && visual.loop.diagnostics.visualAnalyses == 1)
        visual.clock.addTimeInterval(61); await visual.sample()
        assert(visual.captureCount == 3 && visual.analyzeCount == 1)
        visual.clock.addTimeInterval(61); visual.image = "changed-window-image"; await visual.sample()
        assert(visual.captureCount == 5 && visual.analyzeCount == 2 && visual.outputs == [true, true])

        // No window ID is not permission to capture the whole display.
        let noWindow = MonitorFixture()
        noWindow.source = .init(processID: 7, bundleID: "test.editor", appName: "Editor")
        noWindow.visual(); await noWindow.sample()
        assert(noWindow.captureCount == 0 && noWindow.analyzeCount == 0 && noWindow.errors == 1)
        noWindow.source = .init(processID: 7, bundleID: "test.editor", windowID: 0, appName: "Editor")
        noWindow.visual(); await noWindow.sample()
        assert(noWindow.captureCount == 0 && noWindow.analyzeCount == 0 && noWindow.errors == 2)

        // Fresh Chrome coverage replaces native checks. Losing coverage falls
        // back to AX, while a non-Chrome app never uses a browser heartbeat.
        let chrome = MonitorFixture()
        chrome.source = .init(processID: 8, bundleID: "com.google.Chrome", windowID: 44, windowTitle: "Page", appName: "Chrome")
        chrome.text(); chrome.covered = true
        await chrome.sample()
        assert(chrome.textReads == 0 && chrome.captureCount == 0 && chrome.analyzeCount == 0)
        assert(chrome.loop.diagnostics.browserCoverageSkips == 1)
        chrome.covered = false; await chrome.sample()
        assert(chrome.analyzeCount == 1 && chrome.captureCount == 0)
        let editor = MonitorFixture(); editor.covered = true; editor.text(); await editor.sample()
        assert(editor.analyzeCount == 1)

        // Failed attempts must retry the same evidence, then reuse only the
        // completed result. Image failures throttle visual attempts separately
        // from successful receipts, while text failures remain retryable.
        let failure = MonitorFixture(); failure.text(); failure.fail = true
        await failure.sample(); failure.fail = false; await failure.sample(); await failure.sample()
        assert(failure.analyzeCount == 2 && failure.errors == 1 && failure.outputs == [false])
        let imageFailure = MonitorFixture(); imageFailure.visual(); imageFailure.fail = true
        await imageFailure.sample(); imageFailure.fail = false; await imageFailure.sample()
        assert(imageFailure.captureCount == 1 && imageFailure.analyzeCount == 1 && imageFailure.outputs.isEmpty)
        assert(imageFailure.statuses.last == .visualCooldown)
        imageFailure.clock.addTimeInterval(61); await imageFailure.sample()
        assert(imageFailure.captureCount == 3 && imageFailure.analyzeCount == 2 && imageFailure.outputs == [true])

        // Source changes during inference discard the result and never seed a
        // reusable result for the old source. Same-window text edits do too.
        let moved = MonitorFixture(); moved.text(); moved.blockAnalysis = true
        let movingTask = Task { await moved.sample() }
        while moved.analyzeGate == nil { await Task.yield() }
        moved.current = .init(processID: 9, windowID: 55, appName: "Other app")
        moved.release(); await movingTask.value
        assert(moved.outputs.isEmpty && moved.loop.diagnostics.sourceChanges == 1)
        moved.current = nil; moved.blockAnalysis = false; await moved.sample()
        assert(moved.analyzeCount == 2 && moved.outputs == [false])
        let edited = MonitorFixture(); edited.text(); edited.blockAnalysis = true
        let editTask = Task { await edited.sample() }
        while edited.analyzeGate == nil { await Task.yield() }
        edited.text("The document now asks for a different account code and describes a different situation entirely.")
        edited.release(); await editTask.value
        assert(edited.outputs.isEmpty && edited.loop.diagnostics.sourceChanges == 1)
        edited.blockAnalysis = false; await edited.sample()
        assert(edited.analyzeCount == 2 && edited.outputs == [false])
        let repainted = MonitorFixture(); repainted.visual(); repainted.blockAnalysis = true
        let repaintTask = Task { await repainted.sample() }
        while repainted.analyzeGate == nil { await Task.yield() }
        repainted.image = "the canvas changed while inference was running"
        repainted.release(); await repaintTask.value
        assert(repainted.outputs.isEmpty && repainted.loop.diagnostics.sourceChanges == 1)
        repainted.blockAnalysis = false; await repainted.sample()
        assert(repainted.analyzeCount == 1 && repainted.outputs.isEmpty && repainted.statuses.last == .visualCooldown)
        repainted.clock.addTimeInterval(61); await repainted.sample()
        assert(repainted.analyzeCount == 2 && repainted.outputs == [true])

        // A visual cooldown does not delay fresh meaningful text in the same
        // window, even if a previous image attempt failed.
        let visualThenText = MonitorFixture(); visualThenText.visual(); visualThenText.fail = true
        await visualThenText.sample()
        visualThenText.fail = false; visualThenText.text()
        await visualThenText.sample()
        assert(visualThenText.captureCount == 1 && visualThenText.analyzeCount == 2 && visualThenText.outputs == [false])

        // Pause cancels/invalidate in-flight checks, ignores even a transport
        // that returns after cancellation, and allows fresh work after restart.
        let paused = MonitorFixture(); paused.text(); paused.blockAnalysis = true
        let pausedTask = Task { await paused.sample() }
        while paused.analyzeGate == nil { await Task.yield() }
        paused.loop.stop(); paused.release(); await pausedTask.value
        assert(paused.outputs.isEmpty && paused.errors == 0)
        paused.blockAnalysis = false; await paused.sample()
        assert(paused.analyzeCount == 2 && paused.outputs == [false])

        // The bounded cache preserves separate windows and evicts old sources.
        var cache = MonitorEvidenceCache(maximumSources: 2)
        let a = text.source, b = ScreenSourceIdentity(processID: 2), c = ScreenSourceIdentity(processID: 3)
        cache.rememberText(1, source: a, now: Date(timeIntervalSince1970: 1))
        cache.rememberText(2, source: b, now: Date(timeIntervalSince1970: 2))
        cache.rememberText(3, source: c, now: Date(timeIntervalSince1970: 3))
        assert(!cache.containsText(1, source: a) && cache.containsText(2, source: b) && cache.containsText(3, source: c))
        cache.beginVisualAttempt(source: a, now: Date(timeIntervalSince1970: 10))
        assert(cache.visualCoolingDown(source: a, now: Date(timeIntervalSince1970: 20)))
        assert(!cache.containsText(99, source: a) && !cache.containsImage(99, text: 99, source: a),
            "Attempt throttles cannot create successful evidence receipts.")
        assert(!cache.visualCoolingDown(source: a, now: Date(timeIntervalSince1970: 71)))
        print("PASS: text-first monitoring, targeted visual fallback/cooldown, Chrome coverage, success-only bounded reuse, source freshness and cancellation")
    }
}
