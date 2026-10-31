import AppKit
import Foundation

enum MonitorLoopStatus: Equatable {
    case sampling, skippedDuplicate, skippedOwnApp, skippedBrowserCoverage, browserCheckPending, visualCooldown, sourceChanged
    case analyzingText(String)
    case analyzingScreenshot(String)
    var label: String {
        switch self {
        case .sampling: return "Reading current window"
        case .skippedDuplicate: return "No relevant window change"
        case .skippedOwnApp: return "Waiting for another app"
        case .skippedBrowserCoverage: return "Chrome is checked by the extension"
        case .browserCheckPending: return "Chrome's current page is being checked"
        case .visualCooldown: return "Waiting before another visual check"
        case .sourceChanged: return "Window changed; waiting for fresh context"
        case let .analyzingText(appName): return "Checking text in \(appName)"
        case let .analyzingScreenshot(appName): return "Checking visual content in \(appName)"
        }
    }
}

enum MonitorContextError: LocalizedError {
    case noTargetWindow
    var errorDescription: String? { "Muse could not identify the current window for a visual check. No desktop screenshot was taken." }
}

/// Text is the normal path. Images are limited to a positively identified
/// current window with missing/visual evidence, never the whole desktop.
@MainActor
final class MonitorLoop {
    /// Fixed diagnostic codes and user-facing explanations only. Never copy
    /// an underlying error's description, model output or screen evidence.
    enum PredictionFailureReason: String {
        case sourceChanged = "source_changed"
        case cancelled
        case screenRecordingRequired = "screen_recording_required"
        case accessibilityRequired = "accessibility_required"
        case windowUnavailable = "window_unavailable"
        case captureFailed = "capture_failed"
        case imageEncodingFailed = "image_encoding_failed"
        case contextUnavailable = "context_unavailable"
        case modelUnavailable = "model_unavailable"
        case modelBusy = "model_busy"
        case modelTimeout = "model_timeout"
        case modelResponseInvalid = "model_response_invalid"
        case modelVerdictInvalid = "model_verdict_invalid"
        case modelRequestFailed = "model_request_failed"
        case networkUnavailable = "network_unavailable"
        case unknown

        var message: String {
            switch self {
            case .sourceChanged: return "Activity changed during the check. Waiting for fresh context."
            case .cancelled: return "This check was stopped. Waiting for fresh context."
            case .screenRecordingRequired: return "Allow Screen Recording for a visual check, or Accessibility for text."
            case .accessibilityRequired: return "Accessibility access is needed to read this window."
            case .windowUnavailable: return "The current window could not be identified. Focus its main window and retry."
            case .captureFailed: return "This window could not be captured. Switch back to it and retry."
            case .imageEncodingFailed: return "The window image could not be prepared for the model."
            case .contextUnavailable: return "Readable context is unavailable for the current window."
            case .modelUnavailable: return "The local model is unavailable. Check its status in the Muse menu."
            case .modelBusy: return "The local model is busy. This check will retry."
            case .modelTimeout: return "The local model timed out. This check will retry."
            case .modelResponseInvalid: return "The local model returned an incomplete response. This check will retry."
            case .modelVerdictInvalid: return "The local model returned an invalid assessment. This check will retry."
            case .modelRequestFailed: return "The local model rejected this check. See Recent activity for details."
            case .networkUnavailable: return "The connection to the local model failed. This check will retry."
            case .unknown: return "This check failed. See Recent activity for details."
            }
        }

        static func classify(_ error: Error) -> PredictionFailureReason {
            if error is CancellationError { return .cancelled }
            if let error = error as? URLError {
                switch error.code {
                case .cancelled: return .cancelled
                case .timedOut: return .modelTimeout
                case .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .badServerResponse: return .modelResponseInvalid
                default: return .networkUnavailable
                }
            }
            if error is MonitorContextError { return .windowUnavailable }
            if let error = error as? ScreenshotCaptureError {
                switch error {
                case .permissionRequired: return .screenRecordingRequired
                case .captureFailed: return .captureFailed
                case .encodeFailed: return .imageEncodingFailed
                }
            }
            if let error = error as? ScreenReaderError {
                switch error {
                case .accessibilityPermissionRequired: return .accessibilityRequired
                case .noFrontmostApplication, .noReadableContent: return .contextUnavailable
                case .ownAppIsFocused: return .cancelled
                }
            }
            if let error = error as? LocalRiskAnalyzerError {
                switch error {
                case .unavailable: return .modelUnavailable
                case .requestFailed: return .modelRequestFailed
                case .invalidResponse: return .modelResponseInvalid
                case .malformedVerdict: return .modelVerdictInvalid
                case .invalidScreenshot: return .imageEncodingFailed
                case .interruptedChat: return .cancelled
                }
            }
            if error is LocalInferenceScheduler.SchedulerError { return .modelBusy }
            if error is DecodingError { return .modelResponseInvalid }
            return .unknown
        }
    }

    struct PredictionObservation {
        enum Phase { case source, evidence, checking, completed, unavailable, cancelled }
        let phase: Phase
        let source: ScreenSourceIdentity
        let requestID: String
        let evidenceIdentity: Int?
        let textIdentity: Int?
        let imageIdentity: Int?
        let browserIdentity: Int?
        let visual: Bool
        let verdict: RiskVerdict?
        let failureReason: PredictionFailureReason?

        init(phase: Phase, source: ScreenSourceIdentity, requestID: String, evidenceIdentity: Int?,
             textIdentity: Int?, imageIdentity: Int?, browserIdentity: Int?, visual: Bool, verdict: RiskVerdict?,
             failureReason: PredictionFailureReason? = nil) {
            self.phase = phase; self.source = source; self.requestID = requestID; self.evidenceIdentity = evidenceIdentity
            self.textIdentity = textIdentity; self.imageIdentity = imageIdentity; self.browserIdentity = browserIdentity
            self.visual = visual; self.verdict = verdict; self.failureReason = failureReason
        }
    }
    /// Reuses observations already collected for monitoring; never initiates
    /// another read, capture or inference for the debug display.
    var onPrediction: (PredictionObservation) -> Void = { _ in }
    /// Identities are process-local hashes of exact current browser context.
    /// Pending transport is separate from completed model coverage. Visual
    /// content always receives the independently verified current-window path.
    enum ChromeCoverage {
        case unavailable
        case covered(identity: Int)
        case pending(identity: Int)
        case visual(snapshot: ScreenSnapshot, identity: Int, isCurrent: @MainActor () async -> Bool)
    }
    struct Dependencies {
        var focusedSource: () throws -> ScreenSourceIdentity
        var readText: (ScreenSourceIdentity) async throws -> ScreenSnapshot?
        var isCurrent: (ScreenSourceIdentity) -> Bool
        var captureWindow: (ScreenSourceIdentity) async throws -> CapturedScreenshot
        var analyze: (ScreenSnapshot, String?, String) async throws -> RiskVerdict
        var chromeCoverage: (ScreenSourceIdentity) async -> ChromeCoverage
        var now: () -> Date = Date.init
        var ignoredProcess: (Int32) -> Bool = { _ in false }
    }
    /// Content-free session counters. Reset when monitoring starts again.
    struct Diagnostics {
        var textAnalyses = 0
        var visualAnalyses = 0
        var windowCaptures = 0
        var duplicateSkips = 0
        var browserCoverageSkips = 0
        var sourceChanges = 0
        var lastMode = "none"
        var lastOutcome = "waiting"
        var lastFailureReason: PredictionFailureReason?
    }
    private(set) var diagnostics = Diagnostics()
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var sampleID: UUID?
    private var activationObserver: NSObjectProtocol?
    private var activationHandler: ((Int32) -> Void)?
    private let activationCenter = NSWorkspace.shared.notificationCenter
    private var activeSource: ScreenSourceIdentity?
    private var analysisTask: Task<RiskVerdict, Error>?
    private var generation = 0
    private var sampling = false
    private var cache = MonitorEvidenceCache()
    private var browserIdentity: Int?

    init(screenReader: ScreenReader, riskAnalyzer: LocalRiskAnalyzer, screenshotCapture: ScreenshotCapture,
         chromeCoverage: @escaping (ScreenSourceIdentity) async -> ChromeCoverage = { _ in .unavailable },
         ignoredProcess: @escaping (Int32) -> Bool = { _ in false },
         watchedApplication: (() -> NSRunningApplication?)? = nil) {
        let application = watchedApplication ?? { NSWorkspace.shared.frontmostApplication }
        dependencies = Dependencies(
            focusedSource: {
                guard let app = application() else { throw ScreenReaderError.ownAppIsFocused }
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !ignoredProcess(app.processIdentifier) else {
                    throw ScreenReaderError.ownAppIsFocused
                }
                guard let source = screenReader.sourceIdentity(for: app) else { throw ScreenReaderError.noFrontmostApplication }
                return source
            },
            readText: { source in
                guard AccessibilityPermissionController.isTrusted,
                      let app = NSRunningApplication(processIdentifier: source.processID), !app.isTerminated else { return nil }
                do { return try await screenReader.readContextAsync(for: app, maxCharacters: 3_000) }
                catch is CancellationError { throw CancellationError() }
                catch { return nil }
            },
            isCurrent: { source in
                guard let app = application(), app.processIdentifier == source.processID,
                      !ignoredProcess(app.processIdentifier) else { return false }
                return screenReader.sourceIdentity(for: app) == source
            },
            captureWindow: { source in
                guard let windowID = source.windowID, windowID > 0 else { throw MonitorContextError.noTargetWindow }
                return try await screenshotCapture.captureAsync(windowID: windowID)
            },
            analyze: { snapshot, image, model in
                if let image {
                    return try await riskAnalyzer.analyze(snapshot: snapshot, screenshotDataURL: image, model: model, priority: .background, scope: .desktop)
                }
                return try await riskAnalyzer.analyze(snapshot: snapshot, model: model, priority: .background, directAnswer: true, scope: .desktop)
            }, chromeCoverage: chromeCoverage, ignoredProcess: ignoredProcess)
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func start(model: String, intervalSeconds: Double = 3,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Bool,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void) {
        stop(); diagnostics = Diagnostics()
        activationHandler = { [weak self] processID in
            guard let self else { return }
            if self.activeSource?.processID != processID { self.cancelCurrentSample() }
            self.requestSample(model: model, onStatus: onStatus, onVerdict: onVerdict, onError: onError)
        }
        activationObserver = activationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self.applicationActivated(processID: app.processIdentifier)
                    }
                }
            }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.requestSample(model: model, onStatus: onStatus, onVerdict: onVerdict, onError: onError)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, intervalSeconds) * 1_000_000_000))
            }
        }
    }
    func stop() {
        if let activationObserver { activationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        activationHandler = nil
        task?.cancel(); task = nil
        cancelCurrentSample()
        cache.removeAll()
        browserIdentity = nil
        diagnostics.lastOutcome = "stopped"
    }
    /// The actual workspace notification and deterministic tests share this
    /// ingress. Muse/renderer activation cannot invalidate a delivered warning.
    func applicationActivated(processID: Int32) {
        guard processID != ProcessInfo.processInfo.processIdentifier,
              !dependencies.ignoredProcess(processID) else { return }
        activationHandler?(processID)
    }
    private func cancelCurrentSample() {
        generation += 1
        sampleTask?.cancel(); sampleTask = nil; sampleID = nil
        analysisTask?.cancel(); analysisTask = nil
        sampling = false; activeSource = nil
    }
    private func requestSample(model: String, onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Bool,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void) {
        guard sampleTask == nil else { return }
        let id = UUID(); sampleID = id
        sampleTask = Task { [weak self] in
            await self?.sampleOnce(model: model, onStatus: onStatus, onVerdict: onVerdict, onError: onError)
            guard let self, self.sampleID == id else { return }
            self.sampleTask = nil; self.sampleID = nil
        }
    }

    /// Deterministic dependencies exercise this same routing without screen
    /// permission, UI automation, real user content or a live model.
    func sampleOnce(model: String,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Bool,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void) async {
        guard !sampling else { return }
        sampling = true
        let stamp = generation
        defer { if generation == stamp { sampling = false; analysisTask = nil; activeSource = nil } }
        var snapshot: ScreenSnapshot?
        var attemptedSource: ScreenSourceIdentity?
        let predictionRequestID = UUID().uuidString
        var predictionEvidence: Int?
        var predictionText: Int?
        var predictionImage: Int?
        var predictionBrowser: Int?
        var predictionVisual = false
        var predictionFinished = false
        func prediction(_ phase: PredictionObservation.Phase, verdict: RiskVerdict? = nil, failureReason: PredictionFailureReason? = nil) {
            guard generation == stamp, let source = attemptedSource else { return }
            onPrediction(.init(phase: phase, source: source, requestID: predictionRequestID,
                evidenceIdentity: predictionEvidence, textIdentity: predictionText, imageIdentity: predictionImage,
                browserIdentity: predictionBrowser, visual: predictionVisual, verdict: verdict, failureReason: failureReason))
        }
        defer {
            if !predictionFinished {
                let reason: PredictionFailureReason = diagnostics.lastOutcome == "source_changed" && !Task.isCancelled ? .sourceChanged : .cancelled
                prediction(.cancelled, failureReason: reason)
            }
        }
        do {
            try Task.checkCancellation()
            emit(.sampling, stamp: stamp, callback: onStatus)
            let source = try dependencies.focusedSource()
            activeSource = source
            attemptedSource = source
            prediction(.source)
            var browserSnapshot: ScreenSnapshot?
            var browserIsCurrent: (@MainActor () async -> Bool)?
            if source.bundleID?.hasPrefix("com.google.Chrome") == true {
                let coverage = await dependencies.chromeCoverage(source)
                guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
                let identity: Int?
                switch coverage {
                case .unavailable: identity = nil
                case let .covered(value), let .pending(value): identity = value
                case let .visual(_, value, _): identity = value
                }
                if browserIdentity != identity {
                    cache.removeEvidence(for: source)
                    browserIdentity = identity
                }
                predictionBrowser = identity
                switch coverage {
                case .covered:
                    emit(.skippedBrowserCoverage, stamp: stamp, callback: onStatus); return
                case .pending:
                    emit(.browserCheckPending, stamp: stamp, callback: onStatus); return
                case let .visual(evidence, _, isCurrent):
                    browserSnapshot = evidence; browserIsCurrent = isCurrent
                case .unavailable: break
                }
            }
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            let readable: ScreenSnapshot?
            if let browserSnapshot { readable = browserSnapshot }
            else { readable = try await dependencies.readText(source) }
            guard valid(source, stamp: stamp), readable?.source == nil || readable?.source == source else {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            let evidence = readable ?? ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle,
                text: "No readable window text is available. Inspect only the supplied current-window image.", source: source)
            snapshot = evidence
            let textFingerprint = MonitorEvidenceCache.textFingerprint(evidence)
            predictionEvidence = textFingerprint
            predictionText = textFingerprint
            cache.observeText(textFingerprint, source: source)
            let needsImage = browserIsCurrent != nil || !evidence.evidence.hasMeaningfulText || evidence.evidence.needsVisualContext
            predictionVisual = needsImage
            prediction(.evidence)
            var image: CapturedScreenshot?
            if needsImage {
                if cache.visualCoolingDown(source: source, now: dependencies.now()) {
                    // New semantic text can still be checked; image motion
                    // alone cannot create an unbounded series of model jobs.
                    guard browserIsCurrent == nil, evidence.evidence.hasMeaningfulText,
                          !cache.containsText(textFingerprint, source: source) else {
                        emit(.visualCooldown, stamp: stamp, callback: onStatus); return
                    }
                } else {
                    guard let windowID = source.windowID, windowID > 0 else { throw MonitorContextError.noTargetWindow }
                    cache.beginVisualAttempt(source: source, now: dependencies.now())
                    image = try await dependencies.captureWindow(source)
                    if generation == stamp { diagnostics.windowCaptures += 1 }
                    guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
                    if let image {
                        var identity = Hasher()
                        identity.combine(textFingerprint)
                        let fingerprint = MonitorEvidenceCache.imageFingerprint(image)
                        identity.combine(fingerprint)
                        predictionImage = fingerprint
                        predictionEvidence = identity.finalize()
                        predictionVisual = true
                        prediction(.evidence)
                    }
                    if let image, cache.containsImage(MonitorEvidenceCache.imageFingerprint(image), text: textFingerprint, source: source) {
                        cache.rememberImage(MonitorEvidenceCache.imageFingerprint(image), text: textFingerprint,
                            source: source, now: dependencies.now())
                        emit(.skippedDuplicate, stamp: stamp, callback: onStatus); return
                    }
                }
            } else if cache.containsText(textFingerprint, source: source) {
                emit(.skippedDuplicate, stamp: stamp, callback: onStatus); return
            }
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            if let browserIsCurrent, !(await browserIsCurrent()) {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            emit(image == nil ? .analyzingText(source.appName) : .analyzingScreenshot(source.appName), stamp: stamp, callback: onStatus)
            predictionVisual = image != nil
            prediction(.checking)
            let imageURL = image?.dataURL
            let check = Task { try await dependencies.analyze(evidence, imageURL, model) }
            analysisTask = check
            let verdict = try await withTaskCancellationHandler(operation: { try await check.value }, onCancel: { check.cancel() })
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            // Same-window edits can obsolete text without a new app/window ID.
            if readable != nil && browserIsCurrent == nil {
                let latest = try await dependencies.readText(source)
                guard valid(source, stamp: stamp), let latest,
                      latest.source == nil || latest.source == source else {
                    emit(.sourceChanged, stamp: stamp, callback: onStatus); return
                }
                let latestFingerprint = MonitorEvidenceCache.textFingerprint(latest)
                cache.observeText(latestFingerprint, source: source)
                guard latestFingerprint == textFingerprint else {
                    emit(.sourceChanged, stamp: stamp, callback: onStatus); return
                }
            }
            if let image {
                let latestImage = try await dependencies.captureWindow(source)
                if generation == stamp { diagnostics.windowCaptures += 1 }
                guard valid(source, stamp: stamp),
                      MonitorEvidenceCache.visuallyStable(image, latestImage) else {
                    emit(.sourceChanged, stamp: stamp, callback: onStatus); return
                }
            }
            if let browserIsCurrent, !(await browserIsCurrent()) {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            guard valid(source, stamp: stamp) else { return }
            diagnostics.lastFailureReason = nil
            prediction(.completed, verdict: verdict)
            predictionFinished = true
            let accepted = onVerdict(verdict, evidence, image != nil)
            guard generation == stamp, !Task.isCancelled else { return }
            if (verdict.riskLevel != .high && verdict.riskLevel != .medium) || accepted {
                if let image {
                    cache.rememberImage(MonitorEvidenceCache.imageFingerprint(image), text: textFingerprint,
                        source: source, now: dependencies.now())
                } else { cache.rememberText(textFingerprint, source: source, now: dependencies.now()) }
                diagnostics.lastOutcome = "completed"
            } else { diagnostics.lastOutcome = "warning_pending" }
        } catch ScreenReaderError.ownAppIsFocused {
            emit(.skippedOwnApp, stamp: stamp, callback: onStatus)
        } catch {
            guard generation == stamp, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            if let source = attemptedSource, !dependencies.isCurrent(source) {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            diagnostics.lastOutcome = "unavailable"
            let reason = PredictionFailureReason.classify(error)
            diagnostics.lastFailureReason = reason
            prediction(.unavailable, failureReason: reason)
            predictionFinished = true
            onError(error, snapshot)
        }
    }
    private func valid(_ source: ScreenSourceIdentity, stamp: Int) -> Bool {
        generation == stamp && !Task.isCancelled && dependencies.isCurrent(source)
    }
    private func emit(_ status: MonitorLoopStatus, stamp: Int, callback: (MonitorLoopStatus) -> Void) {
        guard generation == stamp, !Task.isCancelled else { return }
        switch status {
        case .analyzingText: diagnostics.textAnalyses += 1; diagnostics.lastMode = "text"; diagnostics.lastOutcome = "checking"
        case .analyzingScreenshot: diagnostics.visualAnalyses += 1; diagnostics.lastMode = "vision"; diagnostics.lastOutcome = "checking"
        case .skippedDuplicate: diagnostics.duplicateSkips += 1; diagnostics.lastOutcome = "unchanged"
        case .skippedBrowserCoverage: diagnostics.browserCoverageSkips += 1; diagnostics.lastMode = "browser"; diagnostics.lastOutcome = "extension"
        case .browserCheckPending: diagnostics.lastMode = "browser"; diagnostics.lastOutcome = "extension_checking"
        case .sourceChanged:
            diagnostics.sourceChanges += 1; diagnostics.lastOutcome = "source_changed"
            diagnostics.lastFailureReason = .sourceChanged
        case .visualCooldown: diagnostics.lastOutcome = "visual_cooldown"
        case .skippedOwnApp: diagnostics.lastOutcome = "own_app"
        case .sampling: diagnostics.lastOutcome = "reading"
        }
        callback(status)
    }
    deinit {
        if let activationObserver { activationCenter.removeObserver(activationObserver) }
        task?.cancel(); sampleTask?.cancel(); analysisTask?.cancel()
    }
}
