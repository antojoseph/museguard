import Foundation

enum MonitorLoopStatus: Equatable {
    case idle
    case sampling
    case skippedDuplicate
    case skippedOwnApp
    case skippedDeniedApp(String)
    case analyzing(String)
    case sleeping

    var label: String {
        switch self {
        case .idle:
            return "Monitoring paused"
        case .sampling:
            return "Reading focused window"
        case .skippedDuplicate:
            return "No screen change"
        case .skippedOwnApp:
            return "Waiting for another app"
        case let .skippedDeniedApp(appName):
            return "Skipping \(appName)"
        case let .analyzing(appName):
            return "Analyzing \(appName)"
        case .sleeping:
            return "Monitoring"
        }
    }
}

/// Debounced continuous sampler for focused-window text. It analyzes only when
/// readable text changes, which keeps the pet from repeatedly sending the same
/// screen to the model.
@MainActor
final class MonitorLoop {
    private let screenReader: ScreenReader
    private let riskAnalyzer: FireworksRiskAnalyzer
    private var task: Task<Void, Never>?
    private var lastFingerprint: Int?

    init(screenReader: ScreenReader, riskAnalyzer: FireworksRiskAnalyzer) {
        self.screenReader = screenReader
        self.riskAnalyzer = riskAnalyzer
    }

    var isRunning: Bool {
        task != nil
    }

    func start(
        model: String,
        apiKey: String,
        deniedAppNames: [String],
        intervalSeconds: Double = 45,
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict) -> Void,
        onError: @escaping @MainActor (Error) -> Void
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
    }

    private func sampleOnce(
        model: String,
        apiKey: String,
        deniedAppNames: [String],
        onStatus: @escaping @MainActor (MonitorLoopStatus) -> Void,
        onVerdict: @escaping @MainActor (RiskVerdict) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async {
        do {
            onStatus(.sampling)
            let snapshot = try screenReader.readFocusedContext(maxCharacters: 6_000)

            guard !PrivacyFilter.isDenied(snapshot: snapshot, deniedAppNames: deniedAppNames) else {
                onStatus(.skippedDeniedApp(snapshot.appName))
                return
            }

            let fingerprint = Self.fingerprint(for: snapshot)

            guard fingerprint != lastFingerprint else {
                onStatus(.skippedDuplicate)
                return
            }
            lastFingerprint = fingerprint

            onStatus(.analyzing(snapshot.appName))
            let verdict = try await riskAnalyzer.analyze(
                snapshot: snapshot,
                model: model,
                apiKey: apiKey
            )

            guard !Task.isCancelled else { return }
            onVerdict(verdict)
        } catch ScreenReaderError.ownAppIsFocused {
            onStatus(.skippedOwnApp)
        } catch {
            onError(error)
        }
    }

    private static func fingerprint(for snapshot: ScreenSnapshot) -> Int {
        let normalizedText = snapshot.text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var hasher = Hasher()
        hasher.combine(snapshot.appName)
        hasher.combine(snapshot.windowTitle)
        hasher.combine(normalizedText)
        return hasher.finalize()
    }

    deinit {
        task?.cancel()
    }
}
