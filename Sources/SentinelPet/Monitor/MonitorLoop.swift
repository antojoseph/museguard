import AppKit
import Foundation

enum MonitorLoopStatus: Equatable {
    case sampling, skippedDuplicate, skippedOwnApp, skippedBrowserCoverage, visualCooldown, sourceChanged
    case analyzingText(String)
    case analyzingScreenshot(String)
    var label: String {
        switch self {
        case .sampling: return "Reading current window"
        case .skippedDuplicate: return "No relevant window change"
        case .skippedOwnApp: return "Waiting for another app"
        case .skippedBrowserCoverage: return "Chrome is checked by the extension"
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
    struct Dependencies {
        var focusedSource: () throws -> ScreenSourceIdentity
        var readText: (ScreenSourceIdentity) async throws -> ScreenSnapshot?
        var isCurrent: (ScreenSourceIdentity) -> Bool
        var captureWindow: (ScreenSourceIdentity) async throws -> CapturedScreenshot
        var analyze: (ScreenSnapshot, String?, String) async throws -> RiskVerdict
        var chromeCoverage: (ScreenSourceIdentity) async -> Bool
        var now: () -> Date = Date.init
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
    }
    private(set) var diagnostics = Diagnostics()
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var analysisTask: Task<RiskVerdict, Error>?
    private var generation = 0
    private var sampling = false
    private var cache = MonitorEvidenceCache()

    init(screenReader: ScreenReader, riskAnalyzer: LocalRiskAnalyzer, screenshotCapture: ScreenshotCapture,
         chromeCoverage: @escaping (ScreenSourceIdentity) async -> Bool = { _ in false },
         ignoredProcess: @escaping (Int32) -> Bool = { _ in false }) {
        dependencies = Dependencies(
            focusedSource: {
                guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenReaderError.noFrontmostApplication }
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
                guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == source.processID,
                      !ignoredProcess(app.processIdentifier) else { return false }
                return screenReader.sourceIdentity(for: app) == source
            },
            captureWindow: { source in
                guard let windowID = source.windowID, windowID > 0 else { throw MonitorContextError.noTargetWindow }
                return try await screenshotCapture.captureAsync(windowID: windowID)
            },
            analyze: { snapshot, image, model in
                if let image {
                    return try await riskAnalyzer.analyze(snapshot: snapshot, screenshotDataURL: image, model: model, priority: .background)
                }
                return try await riskAnalyzer.analyze(snapshot: snapshot, model: model, priority: .background, directAnswer: true)
            }, chromeCoverage: chromeCoverage)
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func start(model: String, intervalSeconds: Double = 10,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Void,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void) {
        stop(); diagnostics = Diagnostics()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.sampleOnce(model: model, onStatus: onStatus, onVerdict: onVerdict, onError: onError)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, intervalSeconds) * 1_000_000_000))
            }
        }
    }
    func stop() {
        generation += 1
        task?.cancel(); task = nil
        analysisTask?.cancel(); analysisTask = nil
        sampling = false; cache.removeAll()
        diagnostics.lastOutcome = "stopped"
    }

    /// Deterministic dependencies exercise this same routing without screen
    /// permission, UI automation, real user content or a live model.
    func sampleOnce(model: String,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Void,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void) async {
        guard !sampling else { return }
        sampling = true
        let stamp = generation
        defer { if generation == stamp { sampling = false; analysisTask = nil } }
        var snapshot: ScreenSnapshot?
        var attemptedSource: ScreenSourceIdentity?
        do {
            try Task.checkCancellation()
            emit(.sampling, stamp: stamp, callback: onStatus)
            let source = try dependencies.focusedSource()
            attemptedSource = source
            if source.bundleID?.hasPrefix("com.google.Chrome") == true,
               await dependencies.chromeCoverage(source) {
                guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
                emit(.skippedBrowserCoverage, stamp: stamp, callback: onStatus)
                return
            }
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            let readable = try await dependencies.readText(source)
            guard valid(source, stamp: stamp), readable?.source == nil || readable?.source == source else {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            let evidence = readable ?? ScreenSnapshot(appName: source.appName, windowTitle: source.windowTitle,
                text: "No readable window text is available. Inspect only the supplied current-window image.", source: source)
            snapshot = evidence
            let textFingerprint = MonitorEvidenceCache.textFingerprint(evidence)
            let needsImage = !evidence.evidence.hasMeaningfulText || evidence.evidence.needsVisualContext
            var image: CapturedScreenshot?
            if needsImage {
                if cache.visualCoolingDown(source: source, now: dependencies.now()) {
                    // New semantic text can still be checked; image motion
                    // alone cannot create an unbounded series of model jobs.
                    guard evidence.evidence.hasMeaningfulText,
                          !cache.containsText(textFingerprint, source: source) else {
                        emit(.visualCooldown, stamp: stamp, callback: onStatus); return
                    }
                } else {
                    guard let windowID = source.windowID, windowID > 0 else { throw MonitorContextError.noTargetWindow }
                    cache.beginVisualAttempt(source: source, now: dependencies.now())
                    image = try await dependencies.captureWindow(source)
                    if generation == stamp { diagnostics.windowCaptures += 1 }
                    guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
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
            emit(image == nil ? .analyzingText(source.appName) : .analyzingScreenshot(source.appName), stamp: stamp, callback: onStatus)
            let imageURL = image?.dataURL
            let check = Task { try await dependencies.analyze(evidence, imageURL, model) }
            analysisTask = check
            let verdict = try await withTaskCancellationHandler(operation: { try await check.value }, onCancel: { check.cancel() })
            guard valid(source, stamp: stamp) else { emit(.sourceChanged, stamp: stamp, callback: onStatus); return }
            // Same-window edits can obsolete text without a new app/window ID.
            if readable != nil {
                let latest = try await dependencies.readText(source)
                guard valid(source, stamp: stamp), let latest,
                      latest.source == nil || latest.source == source,
                      MonitorEvidenceCache.textFingerprint(latest) == textFingerprint else {
                    emit(.sourceChanged, stamp: stamp, callback: onStatus); return
                }
            }
            if let image {
                let latestImage = try await dependencies.captureWindow(source)
                if generation == stamp { diagnostics.windowCaptures += 1 }
                guard valid(source, stamp: stamp),
                      MonitorEvidenceCache.imageFingerprint(latestImage) == MonitorEvidenceCache.imageFingerprint(image) else {
                    emit(.sourceChanged, stamp: stamp, callback: onStatus); return
                }
            }
            guard valid(source, stamp: stamp) else { return }
            if let image {
                cache.rememberImage(MonitorEvidenceCache.imageFingerprint(image), text: textFingerprint,
                    source: source, now: dependencies.now())
            } else { cache.rememberText(textFingerprint, source: source, now: dependencies.now()) }
            diagnostics.lastOutcome = "completed"
            onVerdict(verdict, evidence, image != nil)
        } catch ScreenReaderError.ownAppIsFocused {
            emit(.skippedOwnApp, stamp: stamp, callback: onStatus)
        } catch {
            guard generation == stamp, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            if let source = attemptedSource, !dependencies.isCurrent(source) {
                emit(.sourceChanged, stamp: stamp, callback: onStatus); return
            }
            diagnostics.lastOutcome = "unavailable"
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
        case .sourceChanged: diagnostics.sourceChanges += 1; diagnostics.lastOutcome = "source_changed"
        case .visualCooldown: diagnostics.lastOutcome = "visual_cooldown"
        case .skippedOwnApp: diagnostics.lastOutcome = "own_app"
        case .sampling: diagnostics.lastOutcome = "reading"
        }
        callback(status)
    }
    deinit { task?.cancel(); analysisTask?.cancel() }
}
