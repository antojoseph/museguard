import AppKit
import Combine
import Foundation

/// Coordinates native context collection, local inference, and explicit guardian events.
@MainActor
final class SentinelPetRuntime: ObservableObject {
    static let shared = SentinelPetRuntime()
    let petViewModel = PetViewModel()
    @Published private(set) var accessibilityTrusted = AccessibilityPermissionController.isTrusted
    @Published private(set) var screenCaptureTrusted = ScreenCapturePermissionController.isTrusted
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitorStatus = "Monitoring paused"
    @Published private(set) var monitoringPaused = MonitoringControl.shared.isPaused
    @Published private(set) var monitoringStatus = "Starting monitoring…"
    @Published private(set) var analysisLogs: [AnalysisLogEntry] = []
    #if MUSE_DEVELOPMENT
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastMockResult: String?
    #endif
    @Published private(set) var downloadStatus = DownloadInspector.installedScanner() == nil ? "Download antivirus unavailable · set up the local scanner" : "Local download scanner installed"
    @Published private(set) var browserStatus = "Browser guard stopped"
    private let browserBridge = BrowserBridgeServer()
    private let browserChatContext = BrowserChatContextBroker()
    private let downloadInspector = DownloadInspector()
    private let downloadMaintenance = DownloadScannerMaintenance()
    private let downloadCommands = BrowserDownloadCommandBroker()
    private let secretPasteMonitor = NativeSecretPasteMonitor()
    private let pointing = BrowserPointingController()
    private var completedDownloadInspections = 0
    private var metadataDownloadChecks = 0
    private var receivedDownloadFiles = 0
    private var failedDownloadInspections = 0
    private var lastDownloadMonitoring: BrowserResponse.DownloadMonitoringMetadata?
    private var downloadTasks: [String: Task<DownloadInspectionResult, Error>] = [:]
    private var warningDownloadActions: [String: (downloadID: Int, holdID: String, action: String)] = [:]
    private var pendingDownloadActions: [String: String] = [:]
    private var recentSafetyNotices: [String: Date] = [:]
    private let monitoringControl = MonitoringControl.shared
    private lazy var browserAssessments: BrowserAssessmentCoordinator = BrowserAssessmentCoordinator(
        modelReady: { LocalModelService.shared.isReady },
        monitoringPaused: { [weak self] in self?.monitoringPaused ?? true },
        onAssessment: { [weak self] request, verdict, snapshot, error in
            guard let self else { return }
            self.recordBrowserPrediction(request: request, verdict: verdict)
            if let verdict, let snapshot {
                self.logVerdict(verdict, source: .browserText, snapshot: snapshot,
                    includesScreenshot: false, updatesChatContext: false)
            } else if let error {
                self.appendLog(AnalysisLogEntry(timestamp: Date(), source: .browserText,
                    appName: snapshot?.appName ?? "Google Chrome", windowTitle: snapshot?.windowTitle,
                    model: LocalModelConfiguration.model, includesScreenshot: false,
                    verdict: nil, errorMessage: error))
            }
        },
        statusDetail: { [weak self] in self?.browserStatus ?? "Muse Guard is closing." },
        desktopMonitoring: { [weak self] in self?.desktopMonitoringMetadata() },
        onProtectionChanged: { [weak self] enabled in
            guard let self else { return }
            self.browserProtection.update(enabled: enabled && !self.monitoringPaused)
        },
        onPresent: { [weak self] request, verdict, snapshot in
            guard let self else { return false }
            guard !self.monitoringPaused, [.medium, .high].contains(verdict.riskLevel) else { return false }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
                self.browserStatus = "Chrome warning received; avatar stayed home because Chrome was not foreground."
                return false
            }
            let warningContext = "browser:" + (request.page?.url ?? snapshot.windowTitle ?? snapshot.appName)
            if self.petViewModel.acknowledgment != nil {
                // Webmail messages share one redacted URL. Merge their new
                // findings by content instead of dropping them as one page.
                _ = self.presentSafety(verdict, context: warningContext, feedbackSource: AnalysisLogSource.browserText.label,
                    feedbackEngine: LocalModelConfiguration.model)
                let wasHidden = self.petViewModel.isAvatarHidden
                self.petViewModel.revealForWarning()
                if wasHidden, let target = self.acknowledgmentTarget { self.petViewModel.intervene(at: target) }
                if let precise = self.resolveBrowserTarget(request), let measurement = request.target {
                    let landing = BrowserPointingController.landingPoint(for: precise.resolved.elementRect)
                    self.petViewModel.intervene(at: landing); self.acknowledgmentTarget = landing
                    self.pointing.show(target: measurement, resolved: precise.resolved, app: precise.app, bounds: precise.bounds, landing: self.petViewModel.interventionAnchor ?? landing)
                }
                return true
            }
            self.updateChatReport(verdict, source: .browserText, snapshot: snapshot)
            // Text-only browser protection needs no Screen Recording access.
            // If macOS withholds Chrome's window metadata, use the current
            // display center after verifying Chrome is foreground.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let fallback = screen.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) }
            let precise = self.resolveBrowserTarget(request)
            let target = precise.map { BrowserPointingController.landingPoint(for: $0.resolved.elementRect) } ?? GuardianTarget.activeWindowCenter(expectedAppName: snapshot.appName) ?? fallback
            self.browserStatus = "Chrome warning delivered to Muse."
            guard self.presentVerdict(verdict, snapshot: snapshot, target: target,
                acknowledgmentID: request.id, acknowledgmentContext: warningContext, requiresAcknowledgment: true,
                feedbackSource: AnalysisLogSource.browserText.label) else { return false }
            if let precise, let target, let measurement = request.target {
                self.pointing.show(target: measurement, resolved: precise.resolved, app: precise.app, bounds: precise.bounds, landing: self.petViewModel.interventionAnchor ?? target)
            }
            if self.petViewModel.acknowledgment != nil { self.browserStatus = "Muse is waiting for Got it." }
            return true
        })
    private let screenReader = ScreenReader()
    private let screenshotCapture = ScreenshotCapture()
    private let riskAnalyzer = LocalRiskAnalyzer()
    private lazy var monitorLoop: MonitorLoop = {
        let loop = MonitorLoop(screenReader: screenReader, riskAnalyzer: riskAnalyzer,
            screenshotCapture: screenshotCapture,
            chromeCoverage: { [weak self] source in await self?.hasFreshBrowserCoverage(source) ?? .unavailable },
            ignoredProcess: { UnrealCharacterRenderer.shared.ownsProcess($0) },
            watchedApplication: { [weak self] in self?.watchedApplication() })
        loop.onPrediction = { [weak self] observation in self?.observeDesktopPrediction(observation) }
        return loop
    }()
    private let settingsWindowController = SettingsWindowController()
    private let analysisLogsWindowController = AnalysisLogsWindowController()
    private var chatTask: Task<Void, Never>?
    #if MUSE_DEVELOPMENT
    private var analysisTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    #endif
    private var latestChatContext: RiskReportChatContext?
    private var lastMonitorErrorMessage: String?
    private var browserSubscriptions = Set<AnyCancellable>()
    private var acknowledgmentContext: String?
    private var acknowledgmentTarget: CGPoint?
    private var warningFeedbackSession: WarningFeedbackSession?
    private var predictionDebugState: PredictionDebugState = {
        let detector = SecretDetector()
        return PredictionDebugState(sanitizeSummary: { detector.detect($0) == nil ? $0 : nil })
    }()
    private var predictionBrowserUpdate: BrowserPredictionUpdate?
    private var predictionBrowserIsPush = false
    private var predictionNewestBrowserExpiry: Int64 = 0
    private var predictionFallbackSources: [Int: String] = [:]
    private var predictionBrowserSourceIDs: [Int: String] = [:]
    private var predictionLastVisualBrowser: (sourceID: String, date: Date)?
    private let predictionTitleSecretDetector = SecretDetector()
    private var predictionBrowserResults: [String: (verdict: RiskVerdict?, date: Date)] = [:]
    private var predictionAppliedBrowserSignature: String?
    private var predictionActiveProcess: Int32?
    private var predictionDesktopSource: ScreenSourceIdentity?
    private var predictionVisualContexts: [String: (key: String, kind: PredictionDebugSourceKind)] = [:]
    private var predictionDebugTask: Task<Void, Never>?
    private var inferenceActivityTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?
    private var menuTrackingDepth = 0
    private var chatRequestID: UUID?
    private var screenChatHistory = ScreenChatHistory()
    private lazy var browserProtection = GuardianProtectionActivity { [weak self] _ in self?.refreshOnDutyAppearance() }
    private init() {
        rememberChatApplication()
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] _ in
            self?.menuTrackingDepth += 1
        }.store(in: &browserSubscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] _ in
            guard let self else { return }
            self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
        }.store(in: &browserSubscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular }
            .sink { [weak self] app in
                if !UnrealCharacterRenderer.shared.ownsProcess(app.processIdentifier) { self?.lastExternalApplication = app }
                self?.refreshPredictionDebug()
            }
            .store(in:&browserSubscriptions)
        inferenceActivityTask = Task {
            let updates = await LocalInferenceScheduler.shared.activityUpdates()
            for await working in updates {
                guard !Task.isCancelled else { break }
                UnrealCharacterRenderer.shared.setInferenceWorking(working)
            }
        }
        petViewModel.$isAvatarHidden.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            guard let self else { return }
            self.cancelChat()
        }.store(in: &browserSubscriptions)
        monitoringControl.$state.sink { [weak self] state in
            self?.applyMonitoringState(paused: state.paused)
        }.store(in: &browserSubscriptions)
        monitoringControl.$browserAcknowledgedRevision.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshMonitoringStatus() }
        }.store(in: &browserSubscriptions)
        monitoringControl.$browserConnected.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshMonitoringStatus() }
        }.store(in: &browserSubscriptions)
        LocalModelService.shared.$isReady.removeDuplicates().sink { [weak self] ready in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ready { self.reconcileDesktopMonitoring() }
                else { self.stopMonitoring() }
                self.refreshMonitoringStatus()
            }
        }.store(in: &browserSubscriptions)
        LocalModelService.shared.$status.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshMonitoringStatus() }
        }.store(in: &browserSubscriptions)
        petViewModel.$isChatOpen.removeDuplicates().filter { !$0 }.sink { [weak self] _ in
            self?.cancelChat()
        }.store(in: &browserSubscriptions)
        predictionDebugTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshPredictionDebug()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func startBrowserBridge() {
        do {
            try browserBridge.start { [weak self] request in
                guard let self else { return .failure(id: request.id, mode: request.mode, message: "Muse Guard is closing.") }
                if request.type == "prediction-update" {
                    do {
                        let checked = try request.validated()
                        guard let update = checked.prediction else { throw BrowserProtocolError.invalidRequest }
                        guard !self.monitoringPaused else {
                            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                                summary: "Prediction display is paused.", guidance: "No activity was selected.")
                        }
                        guard update.expiresAt > self.predictionNewestBrowserExpiry else {
                            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                                summary: "Obsolete prediction metadata ignored.", guidance: "The newer current source remains selected.")
                        }
                        self.predictionNewestBrowserExpiry = update.expiresAt
                        // Retire an earlier Chrome selection on app re-entry
                        // before installing this freshly observed selection.
                        self.refreshPredictionDebug()
                        self.predictionBrowserUpdate = update
                        self.predictionBrowserIsPush = true
                        self.refreshPredictionDebug()
                        return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                            summary: "Current browser prediction context received.", guidance: "Display metadata only; no model check was requested.")
                    } catch { return .failure(id: request.id, message: "Invalid prediction context.") }
                }
                if var controlReply = self.monitoringControl.handle(request) {
                    if request.type == "monitoring-state" { controlReply.downloadCommands = self.downloadCommands.pending() }
                    return controlReply
                }
                if let safetyReply = await self.handleSafetyRequest(request) { return safetyReply }
                if let contextReply = self.browserChatContext.handle(request) { return contextReply }
                if request.type == "assess", request.purpose != nil, !self.monitoringPaused { self.browserProtection.refreshFromAutomaticCheck() }
                var reply = await self.browserAssessments.handle(request)
                if request.type == "status" {
                    var download = self.lastDownloadMonitoring ?? .init(completed: 0, lastStatus: "none", lastScanStatus: "none", scanner: DownloadInspector.installedScanner() == nil ? "unavailable" : "clamav")
                    download.metadataChecks = self.metadataDownloadChecks
                    download.receivedFiles = self.receivedDownloadFiles
                    download.inFlight = self.downloadTasks.count
                    download.failed = self.failedDownloadInspections
                    reply.downloadMonitoring = download
                }
                return reply
            }
            browserStatus = "Browser guard · local connection ready"
            startSecretPasteMonitoring()
            startDownloadMaintenance()
        } catch { browserStatus = "Browser guard unavailable: \(error.localizedDescription)" }
    }
    func stopBrowserBridge() { browserBridge.stop(); downloadMaintenance.stop(); secretPasteMonitor.stop(); pointing.hide(); browserStatus = "Browser guard stopped" }

    func toggleAvatarVisibility() {
        if petViewModel.isAvatarHidden {
            dismissPetBubble()
            petViewModel.setAvatarHidden(false)
            if petViewModel.acknowledgment != nil, let target = acknowledgmentTarget { petViewModel.intervene(at: target) }
        } else {
            petViewModel.setAvatarHidden(true)
            dismissPetBubble()
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
        if accessibilityTrusted { reconcileDesktopMonitoring(); startSecretPasteMonitoring() }
        else if !screenCaptureTrusted { stopMonitoring() }
    }
    func refreshScreenCaptureStatus() {
        screenCaptureTrusted = ScreenCapturePermissionController.isTrusted
        if screenCaptureTrusted { reconcileDesktopMonitoring() }
        else if !accessibilityTrusted { stopMonitoring() }
    }
    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityPermissionController.requestAccess()
        reconcileDesktopMonitoring()
        petViewModel.show(accessibilityTrusted ? "Accessibility is enabled. I can read focused-window text." : "Enable Muse Guard in Privacy & Security → Accessibility, then restart the app.", mood: .idle, clearAfter: 8)
    }
    func requestScreenCapturePermission() {
        screenCaptureTrusted = ScreenCapturePermissionController.requestAccess()
        reconcileDesktopMonitoring()
        petViewModel.show(screenCaptureTrusted ? "Screen Recording is enabled. Analysis stays on this Mac." : "Enable Muse Guard in Privacy & Security → Screen Recording, then restart the app.", mood: .idle, clearAfter: 8)
    }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func openScreenRecordingSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    func showSettings() { settingsWindowController.show(runtime: self) }
    func showAnalysisLogs() { analysisLogsWindowController.show(runtime: self) }
    func clearAnalysisLogs() { analysisLogs.removeAll() }

    #if MUSE_DEVELOPMENT
    private func evaluate(_ snapshot: ScreenSnapshot, image: String?, source: AnalysisLogSource, target: CGPoint? = nil) async throws {
        petViewModel.show("Checking locally with Muse Glimmer…", mood: .scanning)
        let verdict: RiskVerdict
        if let image { verdict = try await riskAnalyzer.analyze(snapshot: snapshot, screenshotDataURL: image, model: LocalModelConfiguration.model) }
        else { verdict = try await riskAnalyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model) }
        try Task.checkCancellation()
        logVerdict(verdict, source: source, snapshot: snapshot, includesScreenshot: image != nil)
        presentVerdict(verdict, snapshot: snapshot, target: target)
    }
    #endif

    func pauseMonitoring(for seconds: TimeInterval = 0) { monitoringControl.pause(for: seconds) }
    func resumeMonitoring() { monitoringControl.resume() }

    private func applyMonitoringState(paused: Bool) {
        monitoringPaused = paused
        predictionDebugState.setPaused(paused)
        predictionAppliedBrowserSignature = nil
        if paused {
            predictionBrowserResults.removeAll()
            predictionBrowserUpdate = nil
            predictionVisualContexts.removeAll()
            predictionBrowserSourceIDs.removeAll()
            predictionLastVisualBrowser = nil
            predictionDebugState.clearCurrentSource()
            stopMonitoring()
            browserAssessments.cancelAll()
            browserProtection.update(enabled: false)
            downloadMaintenance.stop(); downloadStatus = "Download protection paused"
            downloadTasks.values.forEach { $0.cancel() }; downloadTasks.removeAll()
            downloadCommands.cancelAll(); warningDownloadActions.removeAll(); pendingDownloadActions.removeAll()
            petViewModel.setWarningActions([]); pointing.hide()
        } else {
            reconcileDesktopMonitoring()
            startSecretPasteMonitoring()
            startDownloadMaintenance()
        }
        DispatchQueue.main.async { [weak self] in self?.refreshMonitoringStatus() }
        refreshPredictionDebug()
    }

    private func refreshMonitoringStatus() {
        let nextStatus: String
        if monitoringControl.syncPending {
            nextStatus = monitoringControl.browserConnected ?
                (monitoringPaused ? "Pausing browser monitoring…" : "Resuming browser monitoring…") :
                (monitoringPaused ? "Pause saved · waiting for Chrome" : "Waiting for Chrome")
        }
        else if monitoringPaused { nextStatus = "Monitoring paused" }
        else if !LocalModelService.shared.isReady { nextStatus = LocalModelService.shared.status }
        else if !monitoringControl.browserConnected { nextStatus = isMonitoring ? "Desktop checks on · Chrome disconnected" : "Chrome disconnected" }
        else { nextStatus = "Monitoring on" }
        if monitoringStatus != nextStatus { monitoringStatus = nextStatus }
    }

    private func reconcileDesktopMonitoring() {
        guard !monitoringPaused,
              (AccessibilityPermissionController.isTrusted || ScreenCapturePermissionController.isTrusted),
              LocalModelService.shared.isReady else { return }
        if !isMonitoring { startMonitoring() }
    }

    func startMonitoring() {
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
        screenCaptureTrusted = ScreenCapturePermissionController.isTrusted
        guard !isMonitoring, !monitoringPaused,
              (accessibilityTrusted || screenCaptureTrusted), LocalModelService.shared.isReady else { return }
        lastMonitorErrorMessage = nil
        monitorLoop.start(model: LocalModelConfiguration.model,
            onStatus: { [weak self] status in self?.monitorStatus = status.label },
            onVerdict: { [weak self] verdict, snapshot, screenshot in
                guard let self, !self.monitoringPaused else { return false }
                self.lastMonitorErrorMessage = nil
                let interrupt = verdict.riskLevel == .medium || verdict.riskLevel == .high
                self.monitorStatus = "Last local check: \(verdict.riskLevel.rawValue)"
                self.logVerdict(verdict, source: screenshot ? .monitorScreenshot : .monitorText, snapshot: snapshot, includesScreenshot: screenshot, updatesChatContext: interrupt)
                if interrupt { return self.presentVerdict(verdict, snapshot: snapshot, requiresAcknowledgment: true,
                    feedbackSource: (screenshot ? AnalysisLogSource.monitorScreenshot : .monitorText).label) }
                return true
            },
            onError: { [weak self] error, snapshot in
                guard let self else { return }
                self.monitorStatus = "Local analysis unavailable"
                guard error.localizedDescription != self.lastMonitorErrorMessage else { return }
                self.lastMonitorErrorMessage = error.localizedDescription
                // Automatic collection failures belong in status/activity, not
                // in a warning bubble that could seed an unrelated new chat.
                self.logError(error, source: self.monitorLoop.diagnostics.lastMode == "vision" ? .monitorScreenshot : .monitorText, snapshot: snapshot)
            })
        isMonitoring = true
        refreshOnDutyAppearance()
        refreshMonitoringStatus()
    }
    private func stopMonitoring() {
        monitorLoop.stop(); isMonitoring = false; monitorStatus = "Monitoring paused"
        refreshOnDutyAppearance()
        refreshMonitoringStatus()
    }
    private func refreshOnDutyAppearance() {
        // The browser lease still describes Chrome coverage independently;
        // the avatar is on duty while either automatic monitoring path runs.
        UnrealCharacterRenderer.shared.setBrowserProtectionActive(!monitoringPaused &&
            (isMonitoring || browserProtection.isActive))
    }
    func openPetChat() {
        rememberChatApplication()
        if petViewModel.isAvatarHidden { petViewModel.setAvatarHidden(false) }
        let explainsWarning = petViewModel.acknowledgment != nil ||
            (petViewModel.mood == .alert && petViewModel.message != nil)
        let explanation = explainsWarning ? latestChatContext.map { "Why I flagged it:\n\($0.summary)\n\nWhat to do:\n\($0.guidance)" } : nil
        petViewModel.openChat(seedText: explanation)
        petViewModel.chatContextLabel = chatApplication().map { "Chat context · \($0.localizedName ?? "selected app")" } ?? "Chat context refreshes when you ask"
    }
    func dismissPetBubble() {
        cancelChat()
        guard petViewModel.acknowledgment == nil else { return }
        cancelDemo(); latestChatContext = nil
        petViewModel.dismissBubble()
    }
    func closePetChat() { cancelChat(); petViewModel.closeChat() }
    func returnToWarning() { cancelChat(); petViewModel.returnToWarning() }
    func stopPetChatReply() { cancelChat() }
    func resetPetChat() {
        cancelChat()
        screenChatHistory.reset()
        petViewModel.resetChat()
    }
    func returnMuseHome() {
        guard petViewModel.acknowledgment == nil else { return }
        petViewModel.intervention = nil
    }
    func acknowledgeWarning(id: String) {
        dismissWarning(id: id)
    }
    func dismissWarningAsFalsePositive(id: String) {
        dismissWarning(id: id, falsePositive: true)
    }
    private func dismissWarning(id: String, falsePositive: Bool = false) {
        guard petViewModel.acknowledgment?.id == id else { return }
        var dismissalStatus = "Warning acknowledged."
        if falsePositive {
            let details = petViewModel.warningDetails
            let record = warningFeedbackSession?.record(warningID: id,
                summary: details?.summary ?? petViewModel.message ?? "", guidance: details?.guidance ?? "")
            do {
                guard let record else { throw WarningFeedbackError.missingWarning }
                let store = try WarningFeedbackStore()
                try store.record(record)
                dismissalStatus = "False-positive feedback saved on this Mac."
                appendLog(AnalysisLogEntry(timestamp: Date(), source: .warningFeedback, appName: "Muse Guard", windowTitle: nil,
                    model: record.engine, includesScreenshot: false,
                    verdict: RiskVerdict(riskLevel: record.riskLevel ?? .unknown, summary: record.summary,
                        guidance: "You dismissed this warning as a false positive. Feedback was saved on this Mac.", categories: record.categories), errorMessage: nil))
            } catch {
                dismissalStatus = "Warning dismissed; false-positive feedback could not be saved."
                appendLog(AnalysisLogEntry(timestamp: Date(), source: .warningFeedback, appName: "Muse Guard", windowTitle: nil,
                    model: record?.engine ?? "Local feedback", includesScreenshot: false, verdict: nil,
                    errorMessage: "The warning was dismissed, but feedback could not be saved on this Mac."))
            }
        }
        // Acknowledgement dismisses this explanation, never the browser's
        // high-risk block. Native controls never grant a browser action.
        cancelDemo(); cancelChat()
        pointing.hide()
        warningDownloadActions.removeAll()
        acknowledgmentContext = nil; acknowledgmentTarget = nil
        latestChatContext = nil
        warningFeedbackSession = nil
        screenChatHistory.reset()
        petViewModel.acknowledge(id: id)
        petViewModel.restoreVisibilityAfterWarning()
        browserStatus = dismissalStatus
    }
    func askPetChat(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        rememberChatApplication()
        let app = chatApplication()
        if petViewModel.chatMessages.isEmpty { screenChatHistory.reset() }
        if petViewModel.isChatThinking, let previous = chatRequestID {
            petViewModel.interruptAssistantChat(id:previous,message:"Reply stopped.")
        }
        cancelChat()
        let requestID = UUID(); chatRequestID = requestID
        petViewModel.openChat(); petViewModel.appendUserChat(question); petViewModel.beginChatResponse(id:requestID)
        petViewModel.chatContextLabel = isChrome(app) ? "Reading current Chrome page…" : "Reading \(app?.localizedName ?? "current app")…"
        let context = petViewModel.acknowledgment != nil ? latestChatContext : nil
        chatTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.chatRequestID == requestID { self.petViewModel.setChatThinking(false) }
            }
            do {
                var screen: ScreenChatContext?
                var sourceKey = "unavailable:\(app?.processIdentifier ?? -1)"
                do {
                    let fresh = try await self.captureChatContext(app:app, question:question)
                    guard self.chatRequestID == requestID, self.petViewModel.isChatOpen, !self.petViewModel.isAvatarHidden else { throw CancellationError() }
                    screen = fresh.context; sourceKey = fresh.key
                    self.petViewModel.chatContextLabel = fresh.label
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard self.chatRequestID == requestID, self.petViewModel.isChatOpen, !self.petViewModel.isAvatarHidden else { throw CancellationError() }
                    self.petViewModel.chatContextLabel = self.isChrome(app) ?
                        "Chrome page unavailable · check the Muse Guard extension" : "\(app?.localizedName ?? "Current app") unavailable · check screen access"
                }
                try Task.checkCancellation()
                guard self.chatRequestID == requestID, self.petViewModel.isChatOpen, !self.petViewModel.isAvatarHidden else { return }
                let scopedHistory = self.screenChatHistory.history(for:sourceKey)
                let answer = try await self.riskAnalyzer.answerQuestion(question, context:context,
                    screenContext:screen,history:scopedHistory,model:LocalModelConfiguration.model,
                    directAnswer:screen?.screenshotDataURL == nil,
                    onVisibleAnswer: { [weak self] answer in
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        let accepted = await self.applyStreamedChatAnswer(answer,requestID:requestID)
                        guard accepted else { throw CancellationError() }
                    })
                guard !Task.isCancelled, self.chatRequestID == requestID, self.petViewModel.isChatOpen,
                      !self.petViewModel.isAvatarHidden else { return }
                self.petViewModel.updateAssistantChat(id:requestID,text:answer)
                self.screenChatHistory.append(question:question,answer:answer,sourceKey:sourceKey)
            } catch {
                guard !Task.isCancelled, self.chatRequestID == requestID, self.petViewModel.isChatOpen,
                      !self.petViewModel.isAvatarHidden else { return }
                if !self.petViewModel.interruptAssistantChat(id:requestID,message:"This reply was interrupted. Please retry.") {
                    let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                    self.petViewModel.appendAssistantChat(cancelled ? LocalRiskAnalyzerError.interruptedChat.localizedDescription : error.localizedDescription)
                }
            }
        }
    }

    private func applyStreamedChatAnswer(_ answer:String,requestID:UUID) -> Bool {
        guard chatRequestID == requestID, petViewModel.isChatOpen, !petViewModel.isAvatarHidden else { return false }
        return petViewModel.updateAssistantChat(id:requestID,text:answer)
    }

    /// Invalidate before cancelling: a token callback may already have passed
    /// its task cancellation check and be waiting to enter the main actor.
    private func cancelChat() {
        let previous = chatRequestID
        chatRequestID = nil
        if let previous, petViewModel.isChatStreaming {
            petViewModel.interruptAssistantChat(id:previous,message:"Reply stopped.")
        }
        chatTask?.cancel(); chatTask = nil
        petViewModel.invalidateChatResponse()
    }

    private func rememberChatApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, isContextApplication(app) {
            lastExternalApplication = app
        }
    }
    private func chatApplication() -> NSRunningApplication? { watchedApplication() }
    private func watchedApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previous = lastExternalApplication.flatMap { $0.isTerminated ? nil : $0 }
        let ignored = Set([frontmost, previous].compactMap { app -> Int32? in
            guard let app, UnrealCharacterRenderer.shared.ownsProcess(app.processIdentifier) else { return nil }
            return app.processIdentifier
        })
        let processID = WatchedApplicationPolicy.processToWatch(frontmost: frontmost?.processIdentifier,
            ownProcess: ProcessInfo.processInfo.processIdentifier, chatOpen: petViewModel.isChatOpen,
            keyWindowIdentifier: NSApp.keyWindow?.identifier?.rawValue, lastExternal: previous?.processIdentifier,
            ignoredProcesses: ignored, menuTracking: menuTrackingDepth > 0)
        if let frontmost, frontmost.processIdentifier == processID { return frontmost }
        if let previous, previous.processIdentifier == processID { return previous }
        return nil
    }
    private func isContextApplication(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier && app.activationPolicy == .regular &&
            !UnrealCharacterRenderer.shared.ownsProcess(app.processIdentifier)
    }
    private func isChrome(_ app: NSRunningApplication?) -> Bool { app?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true }
    private func hasFreshBrowserCoverage(_ source: ScreenSourceIdentity) async -> MonitorLoop.ChromeCoverage {
        guard !monitoringPaused, !monitoringControl.syncPending, monitoringControl.browserConnected,
              watchedApplication()?.processIdentifier == source.processID,
              browserProtection.isActive, source.bundleID?.hasPrefix("com.google.Chrome") == true else { return .unavailable }
        do {
            let fresh = try await browserChatContext.requestContext(timeout: 2)
            try Task.checkCancellation()
            guard let app = watchedApplication(), app.processIdentifier == source.processID,
                  screenReader.sourceIdentity(for: app) == source,
                  let quality = fresh.page.evidence else { return .unavailable }
            observePredictionBrowserContext(fresh)
            let identity = fresh.monitoringIdentity
            if quality.needsVisualContext {
                let evidence = ContextEvidence(semanticTextCharacters: quality.primaryTextCharacters,
                    semanticTextElements: quality.primaryTextCharacters > 0 ? 1 : 0,
                    visualElements: quality.substantialVisuals, truncated: quality.truncated, requiresVisual: true)
                let snapshot = ScreenSnapshot(appName: source.appName, windowTitle: fresh.page.title,
                    text: fresh.page.text, evidence: evidence, source: source)
                return .visual(snapshot: snapshot, identity: identity, isCurrent: { [weak self] in
                    guard let self, !self.monitoringPaused, !self.monitoringControl.syncPending,
                          self.monitoringControl.browserConnected, self.browserProtection.isActive,
                          let current = self.watchedApplication(),
                          current.processIdentifier == source.processID,
                          self.screenReader.sourceIdentity(for: current) == source else { return false }
                    do {
                        let latest = try await self.browserChatContext.requestContext(timeout: 2)
                        try Task.checkCancellation()
                        guard !self.monitoringPaused, let current = self.watchedApplication(),
                              current.processIdentifier == source.processID,
                              self.screenReader.sourceIdentity(for: current) == source else { return false }
                        return latest.matchesContent(of: fresh)
                    } catch { return false }
                })
            }
            guard let proof = fresh.coverage, proof.isFresh(at: Date()) else { return .unavailable }
            return proof.state == "completed" ? .covered(identity: identity) : .pending(identity: identity)
        } catch { return .unavailable }
    }

    private func desktopMonitoringMetadata() -> BrowserResponse.DesktopMonitoringMetadata {
        let counters = monitorLoop.diagnostics
        return .init(enabled: isMonitoring, accessibilityReady: AccessibilityPermissionController.isTrusted,
            screenCaptureReady: ScreenCapturePermissionController.isTrusted,
            textAnalyses: counters.textAnalyses, visualAnalyses: counters.visualAnalyses,
            windowCaptures: counters.windowCaptures, duplicateSkips: counters.duplicateSkips,
            browserCoverageSkips: counters.browserCoverageSkips, sourceChanges: counters.sourceChanges,
            lastMode: counters.lastMode, lastOutcome: counters.lastOutcome,
            lastFailureReason: counters.lastFailureReason?.rawValue)
    }

    private func captureChatContext(app: NSRunningApplication?, question: String) async throws -> (context:ScreenChatContext,key:String,label:String) {
        guard let app, !app.isTerminated else { throw ScreenReaderError.noFrontmostApplication }
        let name = app.localizedName ?? "Current app"
        guard let source = screenReader.sourceIdentity(for: app) else { throw ScreenReaderError.noReadableContent(name) }
        func sourceIsCurrent() -> Bool {
            chatApplication()?.processIdentifier == source.processID && screenReader.sourceIdentity(for: app) == source
        }
        var browserContext: BrowserChatContext?
        var snapshot: ScreenSnapshot?
        if isChrome(app), monitoringControl.browserConnected {
            do {
                let fresh = try await browserChatContext.requestContext()
                try Task.checkCancellation()
                guard sourceIsCurrent() else { throw ChatScreenError.changed }
                browserContext = fresh
                let evidence = fresh.page.evidence.map { quality in
                    ContextEvidence(semanticTextCharacters: quality.primaryTextCharacters,
                        semanticTextElements: quality.primaryTextCharacters > 0 ? 1 : 0,
                        visualElements: quality.substantialVisuals, truncated: quality.truncated,
                        requiresVisual: quality.needsVisualContext)
                } ?? .visibleText(fresh.page.text)
                snapshot = ScreenSnapshot(appName: name, windowTitle: fresh.page.title, text: fresh.page.text,
                    evidence: evidence, source: source)
            } catch is CancellationError { throw CancellationError() }
            catch ChatScreenError.changed { throw ChatScreenError.changed }
            catch { /* AX and targeted image capture remain available if the extension cannot read this page. */ }
        }
        if snapshot == nil, AccessibilityPermissionController.isTrusted {
            do { snapshot = try await screenReader.readContextAsync(for: app) }
            catch is CancellationError { throw CancellationError() }
            catch { /* A text-poor window may still expose a useful image. */ }
        }
        try Task.checkCancellation()
        guard sourceIsCurrent(), snapshot?.source == nil || snapshot?.source == source else { throw ChatScreenError.changed }
        let evidence = snapshot ?? ScreenSnapshot(appName: name, windowTitle: source.windowTitle, text: "",
            evidence: .visibleText(""), source: source)
        var image: String?
        var visualNote: String?
        if ChatCapturePolicy.needsVisual(question: question, snapshot: evidence) {
            if !ScreenCapturePermissionController.isTrusted {
                visualNote = "Screen Recording access is unavailable. Only readable text was collected."
            } else if let windowID = source.windowID {
                do { image = try await screenshotCapture.captureAsync(windowID: windowID).dataURL }
                catch is CancellationError { throw CancellationError() }
                catch { visualNote = "The current-window image could not be captured. Only readable text was collected." }
            } else {
                visualNote = "The current window could not be identified for image capture. Only readable text was collected."
            }
        }
        try Task.checkCancellation()
        guard sourceIsCurrent() else { throw ChatScreenError.changed }
        if image != nil, let original = browserContext {
            let latest = try await browserChatContext.requestContext()
            guard sourceIsCurrent(), latest.matchesContent(of: original) else {
                throw ChatScreenError.changed
            }
        } else if image != nil, let original = snapshot {
            let latest = try? await screenReader.readContextAsync(for: app)
            try Task.checkCancellation()
            guard sourceIsCurrent(), latest?.source == nil || latest?.source == source,
                  latest.map({ ContextEvidence.normalizedText($0.text) }) == ContextEvidence.normalizedText(original.text) else {
                throw ChatScreenError.changed
            }
        }
        let origin = browserContext != nil ? "Chrome extension · current visible page" :
            (snapshot == nil ? "Current window" : "Accessibility window text")
        let context = ScreenChatContext(snapshot: evidence,
            sourceLabel: image == nil ? origin : origin + " and current-window image",
            url: browserContext?.page.url, screenshotDataURL: image, visualContextNote: visualNote)
        let key = browserContext.map { "chrome:\($0.tabID):\($0.documentID):\($0.page.url)" } ??
            "app:\(source.processID):\(source.windowID.map(String.init) ?? "unknown")"
        let title = browserContext?.page.title ?? evidence.windowTitle ?? "current window"
        return (context, key, "Using \(name) · \(title)" + (image == nil ? "" : " · visual context"))
    }
    #if MUSE_DEVELOPMENT
    func previewGuardianIntervention() {
        guard petViewModel.acknowledgment == nil else { return }
        cancelDemo()
        petViewModel.show("Demo · Let’s pause and check.\nThis is Muse’s stop gesture preview.", mood: .alert)
        petViewModel.intervene(at: GuardianTarget.demoTarget())
        demoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissPetBubble()
        }
    }
    func analyzeMock(_ scenario: MockScenario) {
        guard modelReady() else { return }
        analysisTask?.cancel(); cancelDemo()
        lastMockResult = nil
        let target = GuardianTarget.demoTarget()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            self.isAnalyzing = true
            defer { self.isAnalyzing = false }
            let snapshot = ScreenSnapshot(appName: "Muse Mock Lab", windowTitle: scenario.title, text: scenario.text)
            do {
                try await self.evaluate(snapshot, image: scenario.imageDataURL(), source: .mock, target: target)
                self.lastMockResult = self.analysisLogs.first?.verdict.map { "\($0.riskLevel.rawValue.uppercased()) · \($0.summary)" }
            } catch {
                guard !Task.isCancelled else { return }
                self.logError(error, source: .mock, snapshot: snapshot)
                self.lastMockResult = error.localizedDescription
                self.petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 10)
            }
        }
    }
    #endif
    private func cancelDemo() {
        #if MUSE_DEVELOPMENT
        demoTask?.cancel(); demoTask = nil
        #endif
    }
    #if MUSE_DEVELOPMENT
    private func modelReady() -> Bool {
        guard LocalModelService.shared.isReady else {
            LocalModelService.shared.start()
            petViewModel.show("Muse Glimmer is starting on this Mac. Try again when the menu says it’s ready.", mood: .scanning, clearAfter: 8)
            return false
        }
        return true
    }
    #endif
    @discardableResult
    private func presentVerdict(_ verdict: RiskVerdict, snapshot: ScreenSnapshot, target: CGPoint? = nil,
        acknowledgmentID: String? = nil, acknowledgmentContext context: String? = nil,
        requiresAcknowledgment: Bool = false, feedbackSource: String = "Desktop text",
        feedbackEngine: String = LocalModelConfiguration.model) -> Bool {
        let watchedProcessID = watchedApplication()?.processIdentifier
        let key: String
        if let context { key = context }
        else {
            // Different windows and new high-risk evidence must not be marked
            // delivered merely because an older warning is still on screen.
            var identity = Hasher()
            identity.combine(snapshot.source)
            identity.combine(snapshot.appName)
            identity.combine(snapshot.windowTitle)
            identity.combine(ContextEvidence.normalizedText(snapshot.text))
            identity.combine(verdict.categories.sorted())
            identity.combine(ContextEvidence.normalizedText(verdict.summary))
            key = "desktop:\(identity.finalize())"
        }
        let risky = verdict.riskLevel == .medium || verdict.riskLevel == .high
        let shouldAcknowledge = verdict.riskLevel == .high || (requiresAcknowledgment && risky)
        if petViewModel.acknowledgment != nil {
            guard shouldAcknowledge else { return false }
            return presentSafety(verdict, context: key, target: target, feedbackSource: feedbackSource, feedbackEngine: feedbackEngine)
        }
        cancelDemo()
        let pinned = risky || verdict.riskLevel == .unknown
        if shouldAcknowledge {
            cancelChat()
            screenChatHistory.reset()
            if petViewModel.isAvatarHidden {
                petViewModel.revealForWarning()
            }
            let text = "\(verdict.summary)\n\(verdict.guidance)\nI’ll stay here until you dismiss this warning."
            let warningID = acknowledgmentID ?? UUID().uuidString
            guard petViewModel.showAcknowledgment(id: warningID, text: text,
                details: GuardianWarningDetails(summary: verdict.summary, guidance: verdict.guidance)) else { return false }
            warningFeedbackSession = WarningFeedbackSession(warningID: warningID,
                source: feedbackSource, engine: feedbackEngine, verdict: verdict)
            acknowledgmentContext = key
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let verifiedTarget = snapshot.source.flatMap { source in
                source.windowID.flatMap { GuardianTarget.verifiedWindowCenter(windowID: $0, processID: source.processID,
                    watchedProcessID: watchedProcessID) }
            }
            let point = target ?? verifiedTarget ?? GuardianTarget.activeWindowCenter(expectedAppName: snapshot.appName) ??
                screen.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) }
            acknowledgmentTarget = point
            if let point { petViewModel.intervene(at: point) }
            return true
        }
        if !risky { petViewModel.intervention = nil }
        petViewModel.show("\(verdict.summary)\n\(verdict.guidance)\nTap to ask me why.", mood: risky ? .alert : (verdict.riskLevel == .unknown ? .scanning : .idle), clearAfter: pinned ? nil : 12)
        if risky, let point = target ?? GuardianTarget.activeWindowCenter(expectedAppName: snapshot.appName) { petViewModel.intervene(at: point) }
        return true
    }

    private func startDownloadMaintenance() {
        downloadMaintenance.start(isEnabled: { [weak self] in self?.monitoringPaused == false },
            onStatus: { [weak self] status in self?.downloadStatus = status })
    }
    private func startSecretPasteMonitoring() {
        guard AccessibilityPermissionController.isTrusted else { return }
        _ = secretPasteMonitor.start(isEnabled: { [weak self] in self?.monitoringPaused == false },
            shouldIgnoreApp: { UnrealCharacterRenderer.shared.ownsProcess($0.processIdentifier) },
            onDetection: { [weak self] processID, detection in
                guard let self, !self.monitoringPaused, let app = NSRunningApplication(processIdentifier: processID) else { return }
                let key = "native-secret:\(processID):\(detection.category.rawValue)"
                if let date = self.recentSafetyNotices[key], Date().timeIntervalSince(date) < 5 { return }
                self.recentSafetyNotices = self.recentSafetyNotices.filter { Date().timeIntervalSince($0.value) < 60 }
                self.recentSafetyNotices[key] = Date()
                let verdict = RiskVerdict(riskLevel: .high,
                    summary: "You may have pasted a \(detection.label) into \(app.localizedName ?? "this app").",
                    guidance: "This was a warning after the paste; Muse could not prevent it. If this was not intentional, undo the paste. If you sent it, revoke or rotate the credential. A wallet recovery phrase should stay private.",
                    categories: detection.categories.map(\.rawValue))
                self.logSafety(verdict, source: .secretPaste, app: app.localizedName ?? "Current app")
                _ = self.presentSafety(verdict, context: key, feedbackSource: AnalysisLogSource.secretPaste.label,
                    feedbackEngine: "Local secret format detector")
            })
    }

    private func resolveBrowserTarget(_ request: BrowserRequest) -> (resolved: BrowserElementTarget.Resolved, app: NSRunningApplication, bounds: CGRect)? {
        guard let target = request.target else { BrowserTargetDiagnostics.record("missing_measurement"); return nil }
        guard request.validTargetIdentity else { BrowserTargetDiagnostics.record("source_mismatch"); return nil }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome" else {
            BrowserTargetDiagnostics.record("chrome_not_foreground"); return nil
        }
        guard let bounds = BrowserPointingController.verifiedWindow(for: target, app: app) else {
            BrowserTargetDiagnostics.record("window_mismatch"); return nil
        }
        let context = BrowserElementTarget.Context(documentID: request.documentID!, revision: request.pageRevision!,
            tabID: request.tabID!, browserWindowID: request.windowID!, windowBounds: bounds,
            primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0, processID: app.processIdentifier,
            screens: NSScreen.screens.map(\.frame))
        guard target.validated(context: context) else { BrowserTargetDiagnostics.record("stale_or_invalid_geometry"); return nil }
        guard let resolved = target.resolve(context: context) else { BrowserTargetDiagnostics.record("viewport_unavailable"); return nil }
        BrowserTargetDiagnostics.record(resolved.basis.rawValue)
        return (resolved, app, bounds)
    }

    private func handleSafetyRequest(_ request: BrowserRequest) async -> BrowserResponse? {
        if request.type == "cancel", let id = request.assessmentID, let task = downloadTasks[id] {
            task.cancel()
            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                summary: "Download inspection cancelled.", guidance: "No file was marked safe or opened.")
        }
        if request.type == "target-update" {
            let renewed: Bool
            if !monitoringPaused, petViewModel.acknowledgment != nil, let target = request.target,
               let precise = resolveBrowserTarget(request) {
                renewed = pointing.renew(target: target, resolved: precise.resolved, app: precise.app, bounds: precise.bounds)
            } else { renewed = false }
            return BrowserResponse(id: request.id, ok: renewed, decision: "review", riskLevel: "unknown", summary: renewed ? "Pointer renewed." : "Pointer expired.", guidance: "No warning or browser action was created.")
        }
        if request.type == "target-invalidated" {
            pointing.invalidate(documentID: request.documentID, tabID: request.tabID, windowID: request.windowID)
            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown", summary: "Pointer cleared.", guidance: "The warning is still waiting for acknowledgement.")
        }
        if request.type == "download-command-result", let result = request.downloadCommand {
            let matched = downloadCommands.complete(result)
            if matched, let actionID = pendingDownloadActions.removeValue(forKey: result.commandID) {
                petViewModel.finishWarningAction(id: actionID, message: result.ok ? "Download action completed." : "Chrome could not complete that download action. Check Chrome’s Downloads.")
            }
            return BrowserResponse(id: request.id, ok: matched, decision: "review", riskLevel: "unknown", summary: matched ? "Download action received." : "Download action expired.", guidance: "No other download was changed.")
        }
        guard ["secret-paste", "download-inspect"].contains(request.type) else { return nil }
        guard !monitoringPaused else { return .failure(id: request.id, message: "All monitoring is paused.") }
        if request.type == "secret-paste", let secret = request.secret,
           let category = SecretCategory(rawValue: secret.category) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
                return .failure(id: request.id, message: "Chrome is no longer foreground. The secret was not replayed.")
            }
            let verdict = RiskVerdict(riskLevel: .high, summary: "I stopped a \(category.label) from being \(secret.phase == "submit" ? "submitted" : "pasted") into this page.",
                guidance: "Keep this secret private. If you intended to enter it here, first verify the destination and pause monitoring. Got it dismisses this warning and never pastes or submits the value.", categories: secret.categories)
            let precise = resolveBrowserTarget(request)
            let landing = precise.map { BrowserPointingController.landingPoint(for: $0.resolved.elementRect) }
            let delivered = presentSafety(verdict, context: "secret:\(request.documentID ?? ""):\(secret.category)", target: landing,
                feedbackSource: AnalysisLogSource.secretPaste.label, feedbackEngine: "Local secret format detector")
            if delivered, let precise, let landing, let target = request.target {
                pointing.show(target: target, resolved: precise.resolved, app: precise.app, bounds: precise.bounds, landing: petViewModel.interventionAnchor ?? landing)
            }
            logSafety(verdict, source: .secretPaste, app: "Google Chrome")
            return BrowserResponse(id: request.id, ok: delivered, decision: delivered ? "block" : "review", riskLevel: "high", summary: verdict.summary, guidance: verdict.guidance, categories: verdict.categories)
        }
        guard let download = request.download, let phase = DownloadInspectionPhase(rawValue: download.phase) else { return .failure(id: request.id, message: "Download metadata was missing.") }
        if phase == .metadata { metadataDownloadChecks += 1 } else { receivedDownloadFiles += 1 }
        guard downloadTasks[request.id] == nil else { return .failure(id: request.id, message: "This inspection is already running.") }
        guard downloadTasks.count < 8 else { return .failure(id: request.id, message: "The local download inspection queue is full. This file has not been scanned.") }
        let input = DownloadInspectionInput(downloadID: download.downloadID, phase: phase, url: download.url,
            finalURL: download.finalURL, filename: download.filename, mime: download.mime, state: download.state,
            danger: download.danger, fileSize: download.fileSize, totalBytes: download.totalBytes)
        let task = Task { try await downloadInspector.inspect(input) }
        downloadTasks[request.id] = task
        defer { downloadTasks.removeValue(forKey: request.id) }
        do {
            let inspection = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !monitoringPaused else { throw CancellationError() }
            let verdict = RiskVerdict(riskLevel: inspection.riskLevel, summary: inspection.summary, guidance: inspection.guidance, categories: inspection.categories)
            downloadStatus = inspection.details.scanStatus == "clean" ? "Last download: no known threats detected" : inspection.summary
            logSafety(verdict, source: .downloadInspection, app: "Google Chrome", engine: inspection.details.scanner == "clamav" ? "Local static inspection · ClamAV" : "Local static inspection · antivirus unavailable")
            if verdict.riskLevel == .high {
                let actions = downloadWarningActions(download)
                _ = presentSafety(verdict, context: "download:\(download.downloadID)", actions: actions,
                    feedbackSource: AnalysisLogSource.downloadInspection.label,
                    feedbackEngine: inspection.details.scanner == "clamav" ? "Local static inspection · ClamAV" : "Local static inspection · antivirus unavailable")
            }
            var response = BrowserResponse(id: request.id, ok: true, decision: verdict.riskLevel == .high ? "block" : "review", riskLevel: verdict.riskLevel.rawValue,
                summary: verdict.summary, guidance: verdict.guidance, categories: verdict.categories)
            let details = inspection.details
            if phase == .complete {
                completedDownloadInspections += 1
                lastDownloadMonitoring = .init(completed: completedDownloadInspections, lastStatus: details.status, lastScanStatus: details.scanStatus, scanner: details.scanner)
            }
            response.downloadInspection = BrowserDownloadStatus(downloadID: details.downloadID, status: details.status, sha256: details.sha256,
                scanner: details.scanner, scanStatus: details.scanStatus, findings: details.findings, signatureStatus: details.signatureStatus)
            return response
        } catch {
            failedDownloadInspections += 1
            return .failure(id: request.id, message: "This download was not fully inspected. \(error is CancellationError ? "Inspection was cancelled." : error.localizedDescription)")
        }
    }

    private func downloadWarningActions(_ download: BrowserDownloadRequest) -> [GuardianWarningAction] {
        guard let hold = download.holdID, !hold.isEmpty else { return [] }
        let kinds: [(String, String)] = download.state == "complete" ? [("show", "Show download in Finder")] :
            (download.ownedPause == true ? [("cancel", "Cancel this download"), ("resume", "Keep downloading anyway")] : [("cancel", "Cancel this download")])
        let rawName = download.filename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "download"
        let printable = String(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) })
        let name = printable.count > 44 ? String(printable.prefix(22)) + "…" + String(printable.suffix(20)) : printable
        return kinds.map { kind, label in
            let id = UUID().uuidString
            warningDownloadActions[id] = (download.downloadID, hold, kind)
            if warningDownloadActions.count > 64 { warningDownloadActions = [:] }
            return GuardianWarningAction(id: id, title: label + " · " + name)
        }
    }
    func performWarningAction(id: String) {
        guard !monitoringPaused, petViewModel.acknowledgment != nil,
              petViewModel.warningActions.contains(where: { $0.id == id }), let action = warningDownloadActions.removeValue(forKey: id) else { return }
        let command = downloadCommands.enqueue(downloadID: action.downloadID, holdID: action.holdID, action: action.action)
        pendingDownloadActions[command.commandID] = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 31_000_000_000)
            guard let self, self.pendingDownloadActions.removeValue(forKey: command.commandID) != nil else { return }
            self.petViewModel.finishWarningAction(id: id, message: "Chrome did not confirm that action. Check Chrome’s Downloads; Muse did not assume it succeeded.")
        }
        petViewModel.finishWarningAction(id: id, message: "Waiting for Chrome…")
        // Remove mutually exclusive buttons for the same hold immediately.
        let obsolete = warningDownloadActions.filter { $0.value.downloadID == action.downloadID && $0.value.holdID == action.holdID }
        for (otherID, _) in obsolete {
            warningDownloadActions.removeValue(forKey: otherID)
            petViewModel.finishWarningAction(id: otherID, message: "Waiting for Chrome…")
        }
    }
    @discardableResult
    private func presentSafety(_ verdict: RiskVerdict, context: String, target: CGPoint? = nil, actions: [GuardianWarningAction] = [],
        feedbackSource: String, feedbackEngine: String) -> Bool {
        if petViewModel.acknowledgment != nil {
            cancelChat(); petViewModel.returnToWarning()
            let wasHidden = petViewModel.isAvatarHidden
            petViewModel.revealForWarning()
            petViewModel.addSafetyNotice(summary: verdict.summary, guidance: verdict.guidance, actions: actions)
            warningFeedbackSession?.include(source: feedbackSource, engine: feedbackEngine, verdict: verdict)
            if let details = petViewModel.warningDetails {
                let risk: RiskLevel = latestChatContext?.riskLevel == .high || verdict.riskLevel == .high ? .high : verdict.riskLevel
                let categories = Array(Set((latestChatContext?.categories ?? []) + verdict.categories)).sorted()
                latestChatContext = RiskReportChatContext(sourceLabel: "Local protection", appName: "Muse Guard", windowTitle: nil,
                    riskLevel: risk, summary: details.summary, guidance: details.guidance, categories: categories)
            }
            if let target { petViewModel.intervene(at: target); acknowledgmentTarget = target }
            else if wasHidden, let target = acknowledgmentTarget { petViewModel.intervene(at: target) }
            return true
        }
        let snapshot = ScreenSnapshot(appName: "Muse Guard", windowTitle: nil, text: "")
        latestChatContext = RiskReportChatContext(sourceLabel: "Local protection", appName: "Muse Guard", windowTitle: nil,
            riskLevel: verdict.riskLevel, summary: verdict.summary, guidance: verdict.guidance, categories: verdict.categories)
        let delivered = presentVerdict(verdict, snapshot: snapshot, target: target, acknowledgmentContext: context, requiresAcknowledgment: true,
            feedbackSource: feedbackSource, feedbackEngine: feedbackEngine)
        if delivered { petViewModel.setWarningActions(actions) }
        return delivered
    }
    private func logSafety(_ verdict: RiskVerdict, source: AnalysisLogSource, app: String, engine: String = "Local secret format detector") {
        appendLog(AnalysisLogEntry(timestamp: Date(), source: source, appName: app, windowTitle: nil,
            model: engine, includesScreenshot: false, verdict: verdict, errorMessage: nil))
    }

    private func logVerdict(_ verdict: RiskVerdict, source: AnalysisLogSource, snapshot: ScreenSnapshot, includesScreenshot: Bool, updatesChatContext: Bool = true) {
        if updatesChatContext { updateChatReport(verdict, source: source, snapshot: snapshot) }
        appendLog(AnalysisLogEntry(timestamp: Date(), source: source, appName: snapshot.appName, windowTitle: snapshot.windowTitle, model: LocalModelConfiguration.model, includesScreenshot: includesScreenshot, verdict: verdict, errorMessage: nil))
    }
    private func logError(_ error: Error, source: AnalysisLogSource, snapshot: ScreenSnapshot?) {
        appendLog(AnalysisLogEntry(timestamp: Date(), source: source, appName: snapshot?.appName ?? source.label, windowTitle: snapshot?.windowTitle, model: LocalModelConfiguration.model, includesScreenshot: false, verdict: nil, errorMessage: error.localizedDescription))
    }
    private func updateChatReport(_ verdict: RiskVerdict, source: AnalysisLogSource, snapshot: ScreenSnapshot) {
        guard petViewModel.acknowledgment == nil else { return }
        latestChatContext = RiskReportChatContext(sourceLabel: source.label, appName: snapshot.appName,
            windowTitle: snapshot.windowTitle, riskLevel: verdict.riskLevel, summary: verdict.summary,
            guidance: verdict.guidance, categories: verdict.categories)
    }
    private func appendLog(_ entry: AnalysisLogEntry) { analysisLogs.insert(entry, at: 0); if analysisLogs.count > 200 { analysisLogs.removeLast() } }

    private func predictionHeading(app: String, title: String?) -> String {
        guard let title, !title.isEmpty, predictionTitleSecretDetector.detect(title) == nil else { return app }
        return "\(app) · \(title)"
    }

    private func publishPredictionDebug() {
        let snapshot = predictionDebugState.snapshot()
        if petViewModel.predictionDebug != snapshot { petViewModel.predictionDebug = snapshot }
    }

    /// Metadata never supplies a verdict. Only locally completed model jobs
    /// can populate this small, in-memory lookup by their original request ID.
    private func recordBrowserPrediction(request: BrowserRequest, verdict: RiskVerdict?) {
        guard request.type == "assess", !monitoringPaused else { return }
        let now = Date()
        predictionBrowserResults[request.id] = (verdict, now)
        predictionBrowserResults = predictionBrowserResults.filter { now.timeIntervalSince($0.value.date) < 300 }
        while predictionBrowserResults.count > 128,
              let oldest = predictionBrowserResults.min(by: { $0.value.date < $1.value.date })?.key {
            predictionBrowserResults.removeValue(forKey: oldest)
        }
        if predictionBrowserUpdate?.assessmentID == request.id, isChrome(watchedApplication()) {
            refreshPredictionDebug()
            applyBrowserPrediction(force: true)
        }
    }

    private func applyBrowserPrediction(force: Bool = false) {
        guard let update = predictionBrowserUpdate,
              update.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000),
              isChrome(watchedApplication()) else { return }
        let signature = "\(update.sourceID)|\(update.assessmentID ?? "")|\(update.phase)"
        guard force || predictionAppliedBrowserSignature != signature else { return }
        predictionAppliedBrowserSignature = signature
        if let visual = predictionLastVisualBrowser, visual.sourceID == update.sourceID,
           predictionDebugState.snapshot().kind == .desktopVisual,
           predictionDebugState.snapshot().phase == .completed,
           let id = update.assessmentID, let text = predictionBrowserResults[id], text.date <= visual.date {
            // Renewing an older text receipt cannot overwrite a newer visual
            // prediction of this same exact page (for example a canvas).
            return
        }
        let key = "browser:\(update.sourceID):\(update.assessmentID ?? update.phase)"
        predictionDebugState.setCurrentSource(key: key, kind: .browser,
            heading: predictionHeading(app: "Chrome", title: update.title))
        let requestID = "\(key):result"
        if let id = update.assessmentID, let result = predictionBrowserResults[id] {
            _ = predictionDebugState.begin(sourceKey: key, requestID: requestID, now: result.date)
            if let verdict = result.verdict {
                _ = predictionDebugState.complete(sourceKey: key, requestID: requestID, verdict: verdict, now: result.date)
            } else { _ = predictionDebugState.fail(sourceKey: key, requestID: requestID, now: result.date) }
        } else if update.phase == "checking" {
            _ = predictionDebugState.begin(sourceKey: key, requestID: requestID)
        } else if update.phase == "unavailable" || update.phase == "completed" {
            _ = predictionDebugState.begin(sourceKey: key, requestID: requestID)
            _ = predictionDebugState.fail(sourceKey: key, requestID: requestID)
        }
        publishPredictionDebug()
    }

    /// Reuse the exact context already fetched by native monitoring. This is
    /// a fallback for an older/disconnected metadata stream, not another poll.
    private func observePredictionBrowserContext(_ context: BrowserChatContext) {
        let now = Date(), milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let identity = context.monitoringIdentity
        if let sourceID = context.predictionSourceID {
            if predictionBrowserSourceIDs.count >= 32, predictionBrowserSourceIDs[identity] == nil { predictionBrowserSourceIDs.removeAll() }
            predictionBrowserSourceIDs[identity] = sourceID
        }
        if predictionBrowserIsPush, let update = predictionBrowserUpdate,
           context.prefersPredictionPush(update,
               resultCompletedAt: update.assessmentID.flatMap { predictionBrowserResults[$0]?.date }, now: now) { return }
        if predictionFallbackSources[identity] == nil {
            if predictionFallbackSources.count >= 32 { predictionFallbackSources.removeAll() }
            predictionFallbackSources[identity] = UUID().uuidString
        }
        let proof = context.coverage.flatMap { $0.isFresh(at: now) ? $0 : nil }
        predictionBrowserUpdate = BrowserPredictionUpdate(sourceID: context.predictionSourceID ?? predictionFallbackSources[identity]!,
            title: String(context.page.title.prefix(250)), tabID: context.tabID, windowID: context.windowID,
            documentID: context.documentID, phase: proof?.state ?? "waiting", assessmentID: proof?.assessmentID,
            expiresAt: milliseconds + 3_000)
        predictionBrowserIsPush = false
        refreshPredictionDebug()
    }

    private func observeDesktopPrediction(_ observation: MonitorLoop.PredictionObservation) {
        guard !monitoringPaused, let app = watchedApplication(), app.processIdentifier == observation.source.processID else { return }
        if predictionActiveProcess != app.processIdentifier {
            predictionActiveProcess = app.processIdentifier
            predictionAppliedBrowserSignature = nil
            if isChrome(app) { predictionBrowserUpdate = nil }
        }
        let source = observation.source
        let base = "desktop:\(source.hashValue)"
        if observation.phase == .source {
            if predictionDesktopSource != source {
                predictionDesktopSource = source
                // Chrome's selected document is more precise than its native
                // window title. Let its source metadata own this transition.
                if !isChrome(app) {
                    predictionDebugState.setCurrentSource(key: base, kind: .desktopText,
                        heading: predictionHeading(app: source.appName, title: source.windowTitle))
                    publishPredictionDebug()
                }
            }
            return
        }
        let browserScope = isChrome(app)
            ? observation.browserIdentity.map(String.init) ?? predictionBrowserUpdate?.sourceID ?? "native-window"
            : "desktop"
        let context = "\(base):\(browserScope):\(observation.textIdentity.map(String.init) ?? "reading")"
        let key = "\(context):\(observation.evidenceIdentity.map(String.init) ?? "reading"):\(observation.visual)"
        if observation.phase == .cancelled {
            _ = predictionDebugState.discard(sourceKey: key, requestID: observation.requestID,
                detail: observation.failureReason?.message ?? "Check superseded. Waiting for fresh context.")
            publishPredictionDebug()
            return
        }
        predictionDesktopSource = source
        if observation.phase == .evidence, observation.visual, observation.imageIdentity == nil {
            // The current text/document was observed, but a capture may be
            // cooling down. Retain only that exact context's last image result.
            let previous = predictionVisualContexts[context]
            predictionDebugState.setCurrentSource(key: previous?.key ?? "\(context):waiting-image",
                kind: previous?.kind ?? .desktopVisual, heading: predictionHeading(app: source.appName, title: source.windowTitle))
            retainPredictionVisualBrowser(observation.browserIdentity)
            publishPredictionDebug()
            return
        }
        if observation.imageIdentity != nil {
            if predictionVisualContexts.count >= 32, predictionVisualContexts[context] == nil { predictionVisualContexts.removeAll() }
            predictionVisualContexts[context] = (key, .desktopVisual)
        }
        predictionDebugState.setCurrentSource(key: key, kind: observation.visual ? .desktopVisual : .desktopText,
            heading: predictionHeading(app: source.appName, title: source.windowTitle))
        switch observation.phase {
        case .checking: _ = predictionDebugState.begin(sourceKey: key, requestID: observation.requestID)
        case .completed:
            if let verdict = observation.verdict {
                let completedAt = Date()
                _ = predictionDebugState.complete(sourceKey: key, requestID: observation.requestID, verdict: verdict, now: completedAt)
                if predictionVisualContexts.count >= 32, predictionVisualContexts[context] == nil { predictionVisualContexts.removeAll() }
                predictionVisualContexts[context] = (key, observation.visual ? .desktopVisual : .desktopText)
            }
        case .unavailable:
            _ = predictionDebugState.begin(sourceKey: key, requestID: observation.requestID)
            _ = predictionDebugState.fail(sourceKey: key, requestID: observation.requestID, detail: observation.failureReason?.message)
        case .source, .evidence, .cancelled: break
        }
        retainPredictionVisualBrowser(observation.browserIdentity)
        publishPredictionDebug()
    }

    private func retainPredictionVisualBrowser(_ identity: Int?) {
        let snapshot = predictionDebugState.snapshot()
        guard snapshot.kind == .desktopVisual, snapshot.phase == .completed,
              let completedAt = snapshot.timestamp, let identity,
              let sourceID = predictionBrowserSourceIDs[identity] else { return }
        // Restoring a cached image result must restore its original precedence,
        // too; visiting another document must not renew or replace its date.
        predictionLastVisualBrowser = (sourceID, completedAt)
    }

    private func refreshPredictionDebug() {
        predictionDebugState.setPaused(monitoringPaused)
        if monitoringPaused { publishPredictionDebug(); return }
        predictionDebugState.setStopped(!LocalModelService.shared.isReady)
        guard let app = watchedApplication() else {
            predictionActiveProcess = nil
            predictionAppliedBrowserSignature = nil
            predictionDebugState.clearCurrentSource()
            publishPredictionDebug()
            return
        }
        if predictionActiveProcess != app.processIdentifier {
            predictionActiveProcess = app.processIdentifier
            predictionDesktopSource = nil
            predictionAppliedBrowserSignature = nil
            if isChrome(app) { predictionBrowserUpdate = nil }
            predictionDebugState.setCurrentSource(key: "app:\(app.processIdentifier)",
                kind: isChrome(app) ? .browser : .desktopText, heading: app.localizedName ?? "Current app")
        }
        if isChrome(app) {
            if let update = predictionBrowserUpdate, update.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000) {
                applyBrowserPrediction()
            } else if predictionAppliedBrowserSignature != nil {
                predictionAppliedBrowserSignature = nil
                predictionDebugState.setCurrentSource(key: "browser:waiting:\(app.processIdentifier)", kind: .browser,
                    heading: "Chrome · waiting for current tab")
            }
        } else if !isMonitoring, !monitoringPaused, LocalModelService.shared.isReady {
            let key = "app:\(app.processIdentifier)"
            predictionDebugState.setCurrentSource(key: key, kind: .desktopText, heading: app.localizedName ?? "Current app")
            if predictionDebugState.snapshot().phase == .waiting {
                let request = UUID().uuidString
                _ = predictionDebugState.begin(sourceKey: key, requestID: request)
                _ = predictionDebugState.fail(sourceKey: key, requestID: request)
            }
        }
        publishPredictionDebug()
    }

    deinit { inferenceActivityTask?.cancel(); predictionDebugTask?.cancel() }
}

private enum ChatScreenError: Error { case changed }
private enum WarningFeedbackError: Error { case missingWarning }
