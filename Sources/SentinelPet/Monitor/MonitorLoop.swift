import AppKit
import Foundation

enum MonitorLoopStatus: Equatable {
    case idle
    case sampling
    case skippedDuplicate
    case skippedOwnApp
    case skippedDeniedApp(String)
    case analyzing(String)
    case analyzingScreenshot(String)
    case sleeping

    var label: String {
        switch self {
        case .idle:
            return "Monitoring paused"
        case .sampling:
            return "Capturing screen"
        case .skippedDuplicate:
            return "No screen change"
        case .skippedOwnApp:
            return "Waiting for another app"
        case let .skippedDeniedApp(appName):
            return "Skipping \(appName)"
        case let .analyzing(appName):
            return "Analyzing \(appName)"
        case let .analyzingScreenshot(appName):
            return "Analyzing screenshot for \(appName)"
        case .sleeping:
            return "Monitoring"
        }
    }
}

/// Debounced continuous sampler for screenshots. Capture runs on a fixed cadence
/// while Fireworks checks run asynchronously, so inference latency does not delay
/// the next screen sample.
@MainActor
final class MonitorLoop {
    private let screenReader: ScreenReader
    private let riskAnalyzer: FireworksRiskAnalyzer
    private let screenshotCapture: ScreenshotCapture
    private var task: Task<Void, Never>?
    private var inferenceTasks: [UUID: Task<Void, Never>] = [:]
    private var lastFingerprint: Int?

    init(
        screenReader: ScreenReader,
        riskAnalyzer: FireworksRiskAnalyzer,
        screenshotCapture: ScreenshotCapture
    ) {
        self.screenReader = screenReader
        self.riskAnalyzer = riskAnalyzer
        self.screenshotCapture = screenshotCapture
    }

    var isRunning: Bool {
        task != nil
    }

    func start(
        model: String,
        apiKey: String,
        deniedAppNames: [String],
        intervalSeconds: Double = 10,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Void,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void
    ) {
        stop()
        lastFingerprint = nil

        task = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.sampleOnce(
                    model: model,
                    apiKey: apiKey,
                    deniedAppNames: deniedAppNames,
                    onStatus: onStatus,
                    onVerdict: onVerdict,
                    onError: onError
                )

                guard !Task.isCancelled else { return }
                onStatus(.sleeping)
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        inferenceTasks.values.forEach { $0.cancel() }
        inferenceTasks.removeAll()
    }

    private func sampleOnce(
        model: String,
        apiKey: String,
        deniedAppNames: [String],
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Void,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void
    ) async {
        var snapshot: ScreenSnapshot?

        do {
            onStatus(.sampling)
            let screenSnapshot = try currentScreenContext()
            snapshot = screenSnapshot

            guard !PrivacyFilter.isDenied(snapshot: screenSnapshot, deniedAppNames: deniedAppNames) else {
                onStatus(.skippedDeniedApp(screenSnapshot.appName))
                return
            }

            let screenshot = try screenshotCapture.capture()
            let fingerprint = Self.fingerprint(for: screenSnapshot, screenshot: screenshot)

            guard fingerprint != lastFingerprint else {
                onStatus(.skippedDuplicate)
                return
            }
            lastFingerprint = fingerprint

            onStatus(.analyzingScreenshot(screenSnapshot.appName))
            startInference(
                snapshot: screenSnapshot,
                screenshot: screenshot,
                model: model,
                apiKey: apiKey,
                onVerdict: onVerdict,
                onError: onError
            )
        } catch ScreenReaderError.ownAppIsFocused {
            onStatus(.skippedOwnApp)
        } catch {
            onError(error, snapshot)
        }
    }

    private func startInference(
        snapshot: ScreenSnapshot,
        screenshot: CapturedScreenshot,
        model: String,
        apiKey: String,
        onVerdict: @escaping @MainActor (RiskVerdict, ScreenSnapshot, Bool) -> Void,
        onError: @escaping @MainActor (Error, ScreenSnapshot?) -> Void
    ) {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }

            defer {
                self.inferenceTasks[id] = nil
            }

            do {
                let verdict = try await self.riskAnalyzer.analyze(
                    snapshot: snapshot,
                    screenshotDataURL: screenshot.dataURL,
                    model: model,
                    apiKey: apiKey
                )

                guard !Task.isCancelled else { return }
                onVerdict(verdict, snapshot, true)
            } catch {
                guard !Task.isCancelled else { return }
                onError(error, snapshot)
            }
        }

        inferenceTasks[id] = task
    }

    private func currentScreenContext() throws -> ScreenSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ScreenReaderError.noFrontmostApplication
        }

        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ScreenReaderError.ownAppIsFocused
        }

        if AccessibilityPermissionController.isTrusted,
           let readableSnapshot = try? screenReader.readFocusedContext(maxCharacters: 3_000) {
            return readableSnapshot
        }

        return ScreenSnapshot(
            appName: app.localizedName ?? app.bundleIdentifier ?? "focused app",
            windowTitle: nil,
            text: "Screenshot-based monitoring sample. Focused-window text was not available."
        )
    }

    private static func fingerprint(for snapshot: ScreenSnapshot, screenshot: CapturedScreenshot) -> Int {
        let normalizedText = snapshot.text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var hasher = Hasher()
        hasher.combine(snapshot.appName)
        hasher.combine(snapshot.windowTitle)
        hasher.combine(normalizedText)
        hasher.combine(screenshot.dataURL)
        return hasher.finalize()
    }

    deinit {
        task?.cancel()
    }
}
