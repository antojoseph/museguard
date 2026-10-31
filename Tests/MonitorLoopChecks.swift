import Foundation
import CoreGraphics
import ImageIO

private enum FixtureError: Error { case failed }

@MainActor private final class MonitorFixture {
    var source = ScreenSourceIdentity(processID: 7, bundleID: "test.editor", windowID: 23, windowTitle: "Guide", appName: "Editor")
    var current: ScreenSourceIdentity?
    var snapshot: ScreenSnapshot?
    var covered = false
    var browserRoute: MonitorLoop.ChromeCoverage?
    var browserCurrent = true
    var browserValidations = 0
    var clock = Date(timeIntervalSince1970: 2_000_000_000)
    var captureCount = 0
    var analyzeCount = 0
    var textReads = 0
    var image = "same-window-image"
    var fail = false
    var analysisError: Error?
    var captureError: Error?
    var risk = RiskLevel.safe
    var acceptsWarning = true
    var analyzeGate: CheckedContinuation<Void, Never>?
    var blockAnalysis = false
    var statuses: [MonitorLoopStatus] = []
    var outputs: [Bool] = []
    var errors = 0
    var images: [String?] = []
    var predictions: [MonitorLoop.PredictionObservation] = []
    lazy var loop: MonitorLoop = {
        let loop = MonitorLoop(dependencies: .init(
        focusedSource: { [unowned self] in source },
        readText: { [unowned self] _ in textReads += 1; return snapshot },
        isCurrent: { [unowned self] value in (current ?? source) == value },
        captureWindow: { [unowned self] value in
            assert(value.windowID == source.windowID && value.windowID != nil)
            captureCount += 1
            if let captureError { throw captureError }
            return CapturedScreenshot(dataURL: image)
        },
        analyze: { [unowned self] _, image, _ in
            analyzeCount += 1; images.append(image)
            if blockAnalysis { await withCheckedContinuation { analyzeGate = $0 } }
            if let analysisError { throw analysisError }
            if fail { throw FixtureError.failed }
            return RiskVerdict(riskLevel: risk, summary: "Read guide", guidance: "No concern", categories: [])
        },
        chromeCoverage: { [unowned self] _ in browserRoute ?? (covered ? .covered(identity: 1) : .unavailable) },
        now: { [unowned self] in clock }))
        loop.onPrediction = { [unowned self] in predictions.append($0) }
        return loop
    }()

    func text(_ text: String = "This is a useful guide with substantial readable document text, rather than toolbar labels.") {
        snapshot = ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle, text: text,
            evidence: .visibleText(text), source: source)
    }
    func visual() {
        snapshot = ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle,
            text: "Canvas", evidence: ContextEvidence(visualElements: 1), source: source)
    }
    func browserVisual(identity: Int = 1) {
        let evidence = snapshot ?? ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle,
            text: "Visible browser controls", evidence: ContextEvidence(requiresVisual: true), source: source)
        browserRoute = .visual(snapshot: evidence, identity: identity, isCurrent: { [unowned self] in
            browserValidations += 1; return browserCurrent
        })
    }
    func sample() async {
        await loop.sampleOnce(model: "fixture", onStatus: { [unowned self] in statuses.append($0) },
            onVerdict: { [unowned self] _, _, image in outputs.append(image); return acceptsWarning },
            onError: { [unowned self] _, _ in errors += 1 })
    }
    func release() { analyzeGate?.resume(); analyzeGate = nil }
}

@main struct MonitorLoopChecks {
    static func pixels(rect: CGRect? = nil, shade: CGFloat = 0.8) -> CapturedScreenshot {
        let context = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: shade, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        if let rect { context.setFillColor(gray: 0, alpha: 1); context.fill(rect) }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        assert(CGImageDestinationFinalize(destination))
        return CapturedScreenshot(dataURL: "data:image/png;base64," + (data as Data).base64EncodedString())
    }
    @MainActor static func main() async {
        // Ordinary readable documents never capture/encode an image. Cached
        // text avoids both capture and inference on every later sample.
        let text = MonitorFixture(); text.text()
        await text.sample()
        let firstPrediction = text.predictions
        assert(firstPrediction.map(\.phase) == [.source, .evidence, .checking, .completed])
        assert(Set(firstPrediction.map(\.requestID)).count == 1 && firstPrediction.allSatisfy { $0.source == text.source && !$0.visual })
        let textIdentity = MonitorEvidenceCache.textFingerprint(text.snapshot!)
        assert(firstPrediction[0].evidenceIdentity == nil && firstPrediction[0].verdict == nil)
        assert(firstPrediction.dropFirst().allSatisfy { $0.evidenceIdentity == textIdentity })
        assert(firstPrediction.dropFirst().allSatisfy { $0.textIdentity == textIdentity && $0.imageIdentity == nil && $0.browserIdentity == nil })
        assert(firstPrediction.dropLast().allSatisfy { $0.verdict == nil })
        assert(firstPrediction.allSatisfy { $0.failureReason == nil } && text.loop.diagnostics.lastFailureReason == nil)
        assert(firstPrediction.last?.verdict?.riskLevel == .safe && firstPrediction.last?.verdict?.summary == "Read guide")
        assert(firstPrediction.last?.verdict?.guidance == "No concern" && firstPrediction.last?.verdict?.categories == [])
        assert(text.textReads == 2 && text.captureCount == 0 && text.analyzeCount == 1,
            "Prediction observations reuse the monitoring sample and its normal post-inference validation.")
        await text.sample()
        let duplicatePrediction = Array(text.predictions.dropFirst(firstPrediction.count))
        assert(duplicatePrediction.map(\.phase) == [.source, .evidence, .cancelled])
        assert(Set(duplicatePrediction.map(\.requestID)).count == 1 && duplicatePrediction[0].requestID != firstPrediction[0].requestID)
        assert(duplicatePrediction.dropFirst().allSatisfy { $0.evidenceIdentity == textIdentity && $0.verdict == nil })
        assert(text.textReads == 3, "Duplicate sampling has its existing single text read, with no new inference or forged completion.")
        assert(text.captureCount == 0 && text.analyzeCount == 1 && text.outputs == [false])
        assert(text.loop.diagnostics.textAnalyses == 1 && text.loop.diagnostics.duplicateSkips == 1)
        text.text("This GUIDE contains case-sensitive account IDs AbCd and other readable document text.")
        await text.sample()
        assert(text.analyzeCount == 2 && text.captureCount == 0)
        text.text("This GUIDE contains case-sensitive account IDs abcd and other readable document text.")
        await text.sample()
        assert(text.analyzeCount == 3 && text.textReads == 7, "Case changes may change meaning and must not be normalized away.")

        // A canvas gets only its positively identified window. Motion cannot
        // trigger image capture before the cooldown, and identical images do
        // not invoke the model again after a later comparison capture.
        let visual = MonitorFixture(); visual.visual()
        await visual.sample()
        let visualPrediction = visual.predictions
        assert(visualPrediction.map(\.phase) == [.source, .evidence, .evidence, .checking, .completed])
        assert(Set(visualPrediction.map(\.requestID)).count == 1 && visualPrediction.allSatisfy { $0.source == visual.source })
        assert(visualPrediction[1].visual && visualPrediction[1].imageIdentity == nil && visualPrediction[2].visual && visualPrediction[2].evidenceIdentity != nil)
        assert(visualPrediction.dropFirst().allSatisfy { $0.textIdentity == MonitorEvidenceCache.textFingerprint(visual.snapshot!) && $0.browserIdentity == nil })
        assert(visualPrediction[2].imageIdentity != nil && visualPrediction.suffix(3).allSatisfy { $0.imageIdentity == visualPrediction[2].imageIdentity })
        assert(visualPrediction.suffix(3).allSatisfy { $0.visual && $0.evidenceIdentity == visualPrediction[2].evidenceIdentity })
        assert(visualPrediction.last?.verdict?.riskLevel == .safe && visual.textReads == 2)
        let beforeVisualCooldown = visual.predictions.count
        await visual.sample()
        let cooldownPrediction = Array(visual.predictions.dropFirst(beforeVisualCooldown))
        assert(cooldownPrediction.map(\.phase) == [.source, .evidence, .cancelled])
        assert(cooldownPrediction.dropFirst().allSatisfy { $0.visual && $0.imageIdentity == nil && $0.textIdentity == visualPrediction[1].textIdentity && $0.verdict == nil },
            "A visual cooldown reports unchanged preliminary text in visual mode, without inventing pixels or a model result.")
        assert(visual.captureCount == 2 && visual.analyzeCount == 1 && visual.outputs == [true])
        assert(visual.loop.diagnostics.windowCaptures == 2 && visual.loop.diagnostics.visualAnalyses == 1)
        let beforeImageDuplicate = visual.predictions.count
        visual.clock.addTimeInterval(61); await visual.sample()
        let imageDuplicate = Array(visual.predictions.dropFirst(beforeImageDuplicate))
        assert(imageDuplicate.map(\.phase) == [.source, .evidence, .evidence, .cancelled])
        assert(imageDuplicate.allSatisfy { $0.verdict == nil }, "A locally matched cached image cannot produce a fresh model completion.")
        assert(visual.captureCount == 3 && visual.analyzeCount == 1)
        visual.clock.addTimeInterval(61); visual.image = "changed-window-image"; await visual.sample()
        assert(visual.captureCount == 5 && visual.analyzeCount == 2 && visual.outputs == [true, true])

        // No window ID is not permission to capture the whole display.
        let noWindow = MonitorFixture()
        noWindow.source = .init(processID: 7, bundleID: "test.editor", appName: "Editor")
        noWindow.visual(); await noWindow.sample()
        assert(noWindow.captureCount == 0 && noWindow.analyzeCount == 0 && noWindow.errors == 1)
        assert(noWindow.predictions.last?.failureReason == .windowUnavailable && noWindow.loop.diagnostics.lastFailureReason == .windowUnavailable)
        noWindow.source = .init(processID: 7, bundleID: "test.editor", windowID: 0, appName: "Editor")
        noWindow.visual(); await noWindow.sample()
        assert(noWindow.captureCount == 0 && noWindow.analyzeCount == 0 && noWindow.errors == 2)

        // Fresh Chrome coverage replaces native checks. Losing coverage falls
        // back to AX, while a non-Chrome app never uses a browser heartbeat.
        let chrome = MonitorFixture()
        chrome.source = .init(processID: 8, bundleID: "com.google.Chrome", windowID: 44, windowTitle: "Page", appName: "Chrome")
        chrome.text(); chrome.covered = true
        await chrome.sample()
        assert(chrome.predictions.map(\.phase) == [.source, .cancelled] && chrome.predictions.allSatisfy { $0.verdict == nil },
            "Extension coverage must not invent a native model result.")
        assert(chrome.textReads == 0 && chrome.captureCount == 0 && chrome.analyzeCount == 0)
        assert(chrome.loop.diagnostics.browserCoverageSkips == 1)
        chrome.covered = false; await chrome.sample()
        assert(chrome.analyzeCount == 1 && chrome.captureCount == 0)
        let editor = MonitorFixture(); editor.covered = true; editor.text(); await editor.sample()
        assert(editor.analyzeCount == 1)

        // A pending text request never claims that a model verdict exists.
        // Image-bearing browser context bypasses readable AX chrome and gets
        // the existing current-window-only, throttled visual route.
        let pendingChrome = MonitorFixture()
        pendingChrome.source = chrome.source; pendingChrome.text()
        pendingChrome.browserRoute = .pending(identity: 10)
        await pendingChrome.sample()
        assert(pendingChrome.predictions.map(\.phase) == [.source, .cancelled] && pendingChrome.predictions.allSatisfy { $0.verdict == nil },
            "An extension request in progress is not a native completed prediction.")
        assert(pendingChrome.textReads == 0 && pendingChrome.analyzeCount == 0 && pendingChrome.captureCount == 0)
        assert(pendingChrome.statuses.last == .browserCheckPending)
        assert(pendingChrome.loop.diagnostics.browserCoverageSkips == 0 && pendingChrome.loop.diagnostics.lastOutcome == "extension_checking")
        let visualChrome = MonitorFixture()
        visualChrome.source = chrome.source; visualChrome.text(); visualChrome.browserVisual()
        await visualChrome.sample()
        assert(visualChrome.textReads == 0 && visualChrome.analyzeCount == 1 && visualChrome.captureCount == 2)
        assert(visualChrome.outputs == [true] && visualChrome.browserValidations == 2)
        await visualChrome.sample()
        assert(visualChrome.analyzeCount == 1 && visualChrome.captureCount == 2 && visualChrome.statuses.last == .visualCooldown,
            "Readable browser chrome cannot cause a text-only result during a required visual cooldown.")
        visualChrome.clock.addTimeInterval(16); await visualChrome.sample()
        assert(visualChrome.analyzeCount == 1 && visualChrome.captureCount == 3,
            "An unchanged browser image is compared locally without repeating model work.")

        // Different browser documents may expose identical title, text and
        // pixels in the same native window. Their exact browser identity must
        // remain distinct even before another image is permitted by cooldown.
        let documentScope = MonitorFixture(); documentScope.source = chrome.source; documentScope.text()
        documentScope.browserVisual(identity: 101); await documentScope.sample()
        let firstDocument = documentScope.predictions.last { $0.phase == .completed }!
        let beforeDocumentChange = documentScope.predictions.count
        documentScope.browserVisual(identity: 202); await documentScope.sample()
        let changedDocument = Array(documentScope.predictions.dropFirst(beforeDocumentChange))
        assert(changedDocument.map(\.phase) == [.source, .evidence, .cancelled])
        assert(changedDocument.dropFirst().allSatisfy { $0.browserIdentity == 202 && $0.visual && $0.imageIdentity == nil && $0.textIdentity == firstDocument.textIdentity && $0.verdict == nil })
        assert(documentScope.textReads == 0 && documentScope.captureCount == 2 && documentScope.analyzeCount == 1,
            "Document identity observation neither bypasses visual cooldown nor adds a capture/inference.")
        documentScope.clock.addTimeInterval(16); await documentScope.sample()
        let secondDocument = documentScope.predictions.last { $0.phase == .completed }!
        assert(firstDocument.browserIdentity == 101 && secondDocument.browserIdentity == 202)
        assert(firstDocument.source == secondDocument.source && firstDocument.textIdentity == secondDocument.textIdentity && firstDocument.imageIdentity == secondDocument.imageIdentity)
        assert(firstDocument.requestID != secondDocument.requestID,
            "An identical-looking replacement document must not inherit the old document's inference identity.")
        assert(documentScope.textReads == 0 && documentScope.captureCount == 4 && documentScope.analyzeCount == 2 && documentScope.outputs == [true, true])

        // A different tab/document (including one the extension handles with
        // text) ends the former visual episode even if it later returns with
        // identical pixels and the same native Chrome window identity.
        for pending in [false, true] {
            let returned = MonitorFixture(); returned.source = chrome.source; returned.text(); returned.browserVisual(identity: 1)
            await returned.sample()
            returned.browserRoute = pending ? .pending(identity: 2) : .covered(identity: 2)
            await returned.sample()
            returned.clock.addTimeInterval(16); returned.browserVisual(identity: 1)
            await returned.sample()
            assert(returned.analyzeCount == 2 && returned.outputs == [true, true],
                "Returning to visual content after another browser episode must not reuse its old verdict forever.")
        }

        // Browser freshness is verified both before inference and after its
        // pixels remain stable. A same-window tab/document/revision change
        // must not display a result using the prior browser evidence.
        let browserMoved = MonitorFixture(); browserMoved.source = chrome.source; browserMoved.text(); browserMoved.browserVisual()
        browserMoved.browserCurrent = false; await browserMoved.sample()
        assert(browserMoved.captureCount == 1 && browserMoved.analyzeCount == 0 && browserMoved.outputs.isEmpty)
        assert(browserMoved.loop.diagnostics.sourceChanges == 1)
        let browserEdited = MonitorFixture(); browserEdited.source = chrome.source; browserEdited.text(); browserEdited.browserVisual()
        browserEdited.blockAnalysis = true
        let browserEditTask = Task { await browserEdited.sample() }
        while browserEdited.analyzeGate == nil { await Task.yield() }
        browserEdited.browserCurrent = false; browserEdited.release(); await browserEditTask.value
        assert(browserEdited.browserValidations == 2 && browserEdited.outputs.isEmpty && browserEdited.loop.diagnostics.sourceChanges == 1)
        assert(browserEdited.predictions.last?.phase == .cancelled && !browserEdited.predictions.contains { $0.phase == .completed })

        // Failed attempts must retry the same evidence, then reuse only the
        // completed result. Image failures throttle visual attempts separately
        // from successful receipts, while text failures remain retryable.
        let failure = MonitorFixture(); failure.text(); failure.fail = true
        await failure.sample()
        assert(failure.predictions.map(\.phase) == [.source, .evidence, .checking, .unavailable])
        assert(failure.predictions.last?.failureReason == .unknown && failure.loop.diagnostics.lastFailureReason == .unknown)
        assert(Set(failure.predictions.map(\.requestID)).count == 1 && failure.predictions.allSatisfy { $0.verdict == nil })
        assert(failure.predictions.dropFirst().allSatisfy { $0.evidenceIdentity == MonitorEvidenceCache.textFingerprint(failure.snapshot!) })
        assert(failure.textReads == 1 && failure.captureCount == 0 && failure.analyzeCount == 1)
        failure.fail = false; await failure.sample(); await failure.sample()
        assert(failure.textReads == 4, "Unavailable observations do not add another acquisition or model request.")
        assert(failure.analyzeCount == 2 && failure.errors == 1 && failure.outputs == [false])
        assert(failure.loop.diagnostics.lastFailureReason == nil, "A successful assessment clears the earlier failure diagnostic.")
        let imageFailure = MonitorFixture(); imageFailure.visual(); imageFailure.fail = true
        await imageFailure.sample(); imageFailure.fail = false; await imageFailure.sample()
        assert(imageFailure.captureCount == 1 && imageFailure.analyzeCount == 1 && imageFailure.outputs.isEmpty)
        assert(imageFailure.statuses.last == .visualCooldown)
        imageFailure.clock.addTimeInterval(10); await imageFailure.sample()
        assert(imageFailure.analyzeCount == 1)
        imageFailure.clock.addTimeInterval(6); await imageFailure.sample()
        assert(imageFailure.captureCount == 3 && imageFailure.analyzeCount == 2 && imageFailure.outputs == [true])

        // Source changes during inference discard the result and never seed a
        // reusable result for the old source. Same-window text edits do too.
        let moved = MonitorFixture(); moved.text(); moved.blockAnalysis = true
        let movingTask = Task { await moved.sample() }
        while moved.analyzeGate == nil { await Task.yield() }
        moved.current = .init(processID: 9, windowID: 55, appName: "Other app")
        moved.release(); await movingTask.value
        assert(moved.outputs.isEmpty && moved.loop.diagnostics.sourceChanges == 1)
        assert(moved.predictions.map(\.phase) == [.source, .evidence, .checking, .cancelled])
        assert(moved.predictions.last?.failureReason == .sourceChanged && moved.loop.diagnostics.lastFailureReason == .sourceChanged)
        assert(Set(moved.predictions.map(\.requestID)).count == 1 && moved.predictions.allSatisfy { $0.source == moved.source && $0.verdict == nil })
        assert(moved.textReads == 1 && moved.captureCount == 0 && moved.analyzeCount == 1)
        moved.current = nil; moved.blockAnalysis = false; await moved.sample()
        assert(moved.analyzeCount == 2 && moved.outputs == [false])
        let edited = MonitorFixture(); edited.text(); edited.blockAnalysis = true
        let editTask = Task { await edited.sample() }
        while edited.analyzeGate == nil { await Task.yield() }
        edited.text("The document now asks for a different account code and describes a different situation entirely.")
        edited.release(); await editTask.value
        assert(edited.outputs.isEmpty && edited.loop.diagnostics.sourceChanges == 1)
        assert(edited.predictions.last?.phase == .cancelled && !edited.predictions.contains { $0.phase == .completed })
        assert(edited.predictions.last?.failureReason == .sourceChanged && !edited.predictions.contains { $0.phase == .unavailable })
        assert(edited.textReads == 2 && edited.captureCount == 0 && edited.analyzeCount == 1)
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
        repainted.clock.addTimeInterval(16); await repainted.sample()
        assert(repainted.analyzeCount == 2 && repainted.outputs == [true])

        // Localized clock/caret-sized pixels and encoding-level noise do not
        // discard a full assessment; a substantial scene change still does.
        let still = pixels()
        let clockTick = pixels(rect: CGRect(x: 900, y: 600, width: 10, height: 10))
        assert(MonitorEvidenceCache.visuallyStable(still, clockTick))
        assert(MonitorEvidenceCache.visuallyStable(still, pixels(shade: 0.79)))
        assert(!MonitorEvidenceCache.visuallyStable(still, pixels(rect: CGRect(x: 100, y: 100, width: 400, height: 200))))
        let ticking = MonitorFixture(); ticking.visual(); ticking.image = still.dataURL; ticking.blockAnalysis = true
        let tickingTask = Task { await ticking.sample() }
        while ticking.analyzeGate == nil { await Task.yield() }
        ticking.image = clockTick.dataURL; ticking.release(); await tickingTask.value
        assert(ticking.outputs == [true] && ticking.loop.diagnostics.sourceChanges == 0)
        let payment = MonitorFixture(); payment.image = still.dataURL; payment.blockAnalysis = true
        let paymentText = "Transfer $100.00 to account Acme before continuing this transaction."
        payment.snapshot = ScreenSnapshot(appName: payment.source.appName, windowTitle: payment.source.windowTitle,
            text: paymentText, evidence: ContextEvidence(semanticTextCharacters: paymentText.count,
                semanticTextElements: 1, visualElements: 2), source: payment.source)
        let paymentTask = Task { await payment.sample() }
        while payment.analyzeGate == nil { await Task.yield() }
        payment.snapshot = ScreenSnapshot(appName: payment.source.appName, windowTitle: payment.source.windowTitle,
            text: paymentText.replacingOccurrences(of: "$100.00", with: "$1000.00"),
            evidence: payment.snapshot!.evidence, source: payment.source)
        payment.image = clockTick.dataURL; payment.release(); await paymentTask.value
        assert(payment.outputs.isEmpty && payment.loop.diagnostics.sourceChanges == 1,
            "Pixel tolerance never bypasses a critical amount/text change.")

        // A serious result refused by the presentation layer is not successful
        // cached evidence. Medium browser findings also require actual avatar
        // delivery; log-only native callbacks can still explicitly accept them.
        for level in [RiskLevel.medium, .high] {
            let serious = MonitorFixture(); serious.text(); serious.risk = level; serious.acceptsWarning = false
            await serious.sample(); await serious.sample()
            assert(serious.analyzeCount == 2 && serious.loop.diagnostics.lastOutcome == "warning_pending")
            let completed = serious.predictions.filter { $0.phase == .completed }
            assert(completed.count == 2 && completed.allSatisfy { $0.verdict?.riskLevel == level },
                "Model completion preserves its actual severity independently of whether the avatar accepted delivery.")
            serious.acceptsWarning = true; await serious.sample(); await serious.sample()
            assert(serious.analyzeCount == 3 && serious.loop.diagnostics.lastOutcome == "unchanged")
        }

        // Returning to an acknowledged danger is a new episode when different
        // content was actually observed, even if that transition's model work
        // became stale before it could finish.
        let repeated = MonitorFixture(); repeated.risk = .high
        let danger = "Permanently delete every backup and production record without a recovery copy."
        repeated.text(danger); await repeated.sample(); await repeated.sample()
        assert(repeated.analyzeCount == 1 && repeated.outputs.count == 1)
        repeated.text("This is a neutral reference document explaining how to browse safely and preserve work.")
        repeated.blockAnalysis = true
        let neutralTask = Task { await repeated.sample() }
        while repeated.analyzeGate == nil { await Task.yield() }
        repeated.text(danger); repeated.release(); await neutralTask.value
        assert(repeated.outputs.count == 1, "A stale transition must not warn using obsolete content.")
        repeated.blockAnalysis = false; await repeated.sample(); await repeated.sample()
        assert(repeated.analyzeCount == 3 && repeated.outputs.count == 2,
            "The returning danger must warn again, then remain quiet while unchanged.")

        // Reading the replacement content during post-inference validation
        // also invalidates old receipts, even before a new sample can begin.
        let intermediate = MonitorFixture(); intermediate.risk = .high
        intermediate.text(danger); await intermediate.sample()
        intermediate.text("Different risky action: transfer every savings balance to an unknown recipient immediately.")
        intermediate.blockAnalysis = true
        let intermediateTask = Task { await intermediate.sample() }
        while intermediate.analyzeGate == nil { await Task.yield() }
        intermediate.text("A neutral screen was observed during validation and no risky action is currently visible.")
        intermediate.release(); await intermediateTask.value
        intermediate.text(danger); intermediate.blockAnalysis = false; await intermediate.sample()
        assert(intermediate.analyzeCount == 3 && intermediate.outputs.count == 2)

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
        assert(!paused.predictions.contains { $0.phase == .completed || $0.phase == .unavailable },
            "Stopping monitoring suppresses even a transport that returns an obsolete verdict.")
        assert(paused.textReads == 1 && paused.captureCount == 0 && paused.analyzeCount == 1)
        paused.blockAnalysis = false; await paused.sample()
        assert(paused.analyzeCount == 2 && paused.outputs == [false])
        assert(paused.predictions.filter { $0.phase == .completed }.count == 1 && paused.textReads == 3)

        // Priority/task cancellation is different from changing screen content
        // and from a real capture/model failure. Neither is an unavailable
        // prediction and neither may publish a late verdict.
        let cancelled = MonitorFixture(); cancelled.text(); cancelled.blockAnalysis = true
        let cancellationTask = Task { await cancelled.sample() }
        while cancelled.analyzeGate == nil { await Task.yield() }
        cancellationTask.cancel(); cancelled.release(); await cancellationTask.value
        assert(cancelled.predictions.last?.phase == .cancelled && cancelled.predictions.last?.failureReason == .cancelled)
        assert(!cancelled.predictions.contains { $0.phase == .completed || $0.phase == .unavailable })
        assert(cancelled.textReads == 1 && cancelled.captureCount == 0 && cancelled.analyzeCount == 1 && cancelled.errors == 0)

        let malformed = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "PRIVATE_DIAGNOSTIC_SECRET"))
        let analysisFailures: [(Error, MonitorLoop.PredictionFailureReason)] = [
            (LocalRiskAnalyzerError.unavailable, .modelUnavailable),
            (LocalRiskAnalyzerError.requestFailed(503), .modelRequestFailed),
            (LocalRiskAnalyzerError.invalidResponse, .modelResponseInvalid),
            (LocalRiskAnalyzerError.malformedVerdict, .modelVerdictInvalid),
            (LocalInferenceScheduler.SchedulerError.busy, .modelBusy),
            (URLError(.timedOut), .modelTimeout),
            (URLError(.networkConnectionLost), .networkUnavailable),
            (URLError(.cannotParseResponse), .modelResponseInvalid),
            (malformed, .modelResponseInvalid)
        ]
        for (error, reason) in analysisFailures {
            let failed = MonitorFixture(); failed.text(); failed.analysisError = error
            await failed.sample()
            assert(failed.predictions.map(\.phase) == [.source, .evidence, .checking, .unavailable])
            assert(failed.predictions.last?.failureReason == reason && failed.loop.diagnostics.lastFailureReason == reason)
            assert(reason.message.utf8.count <= 256 && !reason.message.contains("PRIVATE_DIAGNOSTIC_SECRET"))
            assert(failed.textReads == 1 && failed.captureCount == 0 && failed.analyzeCount == 1 && failed.errors == 1)
        }
        for (error, reason) in [(ScreenshotCaptureError.permissionRequired, MonitorLoop.PredictionFailureReason.screenRecordingRequired),
                                (.captureFailed, .captureFailed), (.encodeFailed, .imageEncodingFailed)] {
            let failed = MonitorFixture(); failed.visual(); failed.captureError = error
            await failed.sample()
            assert(failed.predictions.map(\.phase) == [.source, .evidence, .unavailable])
            assert(failed.predictions.last?.failureReason == reason && failed.loop.diagnostics.lastFailureReason == reason)
            assert(failed.textReads == 1 && failed.captureCount == 1 && failed.analyzeCount == 0 && failed.errors == 1)
        }
        assert(MonitorLoop.PredictionFailureReason.classify(ScreenReaderError.accessibilityPermissionRequired) == .accessibilityRequired)
        assert(MonitorLoop.PredictionFailureReason.classify(ScreenReaderError.noReadableContent("PRIVATE_DIAGNOSTIC_SECRET")) == .contextUnavailable)
        assert(MonitorLoop.PredictionFailureReason.classify(CancellationError()) == .cancelled)

        // A foreground app activation preempts obsolete work and starts the
        // latest source immediately, instead of waiting for a ten-second tick.
        let switched = MonitorFixture(); switched.text(); switched.blockAnalysis = true
        switched.loop.start(model: "fixture", intervalSeconds: 30,
            onStatus: { switched.statuses.append($0) },
            onVerdict: { _, _, image in switched.outputs.append(image); return true },
            onError: { _, _ in switched.errors += 1 })
        while switched.analyzeGate == nil { await Task.yield() }
        switched.source = .init(processID: 88, bundleID: "test.latest", windowID: 99, windowTitle: "Latest", appName: "Latest app")
        switched.text(); switched.blockAnalysis = false
        switched.loop.applicationActivated(processID: 88)
        for _ in 0..<1_000 {
            if !switched.outputs.isEmpty { break }
            await Task.yield()
        }
        assert(switched.analyzeCount == 2 && switched.outputs == [false], "App switching must run the newest source immediately.")
        switched.release()
        for _ in 0..<10 { await Task.yield() }
        assert(switched.outputs == [false], "The cancelled source cannot deliver a late warning.")
        let switchedCompleted = switched.predictions.filter { $0.phase == .completed }
        assert(switchedCompleted.count == 1 && switchedCompleted[0].source == switched.source && switchedCompleted[0].verdict?.riskLevel == .safe)
        assert(switched.predictions.contains { $0.phase == .checking && $0.source.processID == 7 && $0.requestID != switchedCompleted[0].requestID },
            "Activation must not attach an old sample ID or verdict to the replacement source.")
        switched.loop.stop()

        // The shared watched-app policy keeps the external source current
        // when Muse chat takes focus. Its own activation must not cancel a
        // pending high-risk assessment or erase its delivery receipt.
        let chatFocus = MonitorFixture(); chatFocus.text(); chatFocus.risk = .high; chatFocus.blockAnalysis = true
        chatFocus.loop.start(model: "fixture", intervalSeconds: 30, onStatus: { _ in },
            onVerdict: { _, _, image in chatFocus.outputs.append(image); return true }, onError: { _, _ in chatFocus.errors += 1 })
        while chatFocus.analyzeGate == nil { await Task.yield() }
        chatFocus.loop.applicationActivated(processID: ProcessInfo.processInfo.processIdentifier)
        chatFocus.release()
        for _ in 0..<1_000 {
            if !chatFocus.outputs.isEmpty { break }
            await Task.yield()
        }
        assert(chatFocus.analyzeCount == 1 && chatFocus.outputs == [false] && chatFocus.errors == 0,
            "Chat handoff must preserve the watched app's pending warning.")
        let chatCompleted = chatFocus.predictions.filter { $0.phase == .completed }
        assert(chatCompleted.count == 1 && chatCompleted[0].source == chatFocus.source && chatCompleted[0].verdict?.riskLevel == .high)
        assert(Set(chatFocus.predictions.map(\.requestID)).count == 1)
        chatFocus.loop.stop()

        // The bounded cache preserves separate windows and evicts old sources.
        var cache = MonitorEvidenceCache(maximumSources: 2)
        let a = text.source, b = ScreenSourceIdentity(processID: 2), c = ScreenSourceIdentity(processID: 3)
        cache.rememberText(1, source: a, now: Date(timeIntervalSince1970: 1))
        cache.rememberText(2, source: b, now: Date(timeIntervalSince1970: 2))
        cache.rememberText(3, source: c, now: Date(timeIntervalSince1970: 3))
        assert(!cache.containsText(1, source: a) && cache.containsText(2, source: b) && cache.containsText(3, source: c))
        var episodes = MonitorEvidenceCache()
        episodes.rememberText(1, source: a, now: Date())
        episodes.observeText(1, source: a)
        assert(episodes.containsText(1, source: a))
        let newTitle = ScreenSourceIdentity(processID: a.processID, bundleID: a.bundleID,
            windowID: a.windowID, windowTitle: "Different document", appName: a.appName)
        episodes.observeText(2, source: newTitle)
        assert(!episodes.containsText(1, source: a), "A title change in the same physical window ends its previous episode.")
        cache.beginVisualAttempt(source: a, now: Date(timeIntervalSince1970: 10))
        assert(cache.visualCoolingDown(source: a, now: Date(timeIntervalSince1970: 20)))
        assert(!cache.containsText(99, source: a) && !cache.containsImage(99, text: 99, source: a),
            "Attempt throttles cannot create successful evidence receipts.")
        assert(!cache.visualCoolingDown(source: a, now: Date(timeIntervalSince1970: 71)))
        print("PASS: text-first monitoring, targeted visual fallback/cooldown, Chrome coverage, success-only bounded reuse, source freshness and cancellation")
    }
}
