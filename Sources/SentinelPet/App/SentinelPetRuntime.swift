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
    @Published private(set) var browserStatus = "Browser guard stopped"
    private let browserBridge = BrowserBridgeServer()
    private let browserChatContext = BrowserChatContextBroker()
    private let monitoringControl = MonitoringControl.shared
    private lazy var browserAssessments: BrowserAssessmentCoordinator = BrowserAssessmentCoordinator(
        modelReady: { LocalModelService.shared.isReady },
        monitoringPaused: { [weak self] in self?.monitoringPaused ?? true },
        onAssessment: { [weak self] request, verdict, snapshot, error in
            guard let self else { return }
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
            guard !self.monitoringPaused, verdict.riskLevel == .high else { return false }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
                self.browserStatus = "Chrome warning received; avatar stayed home because Chrome was not foreground."
                return false
            }
            let warningContext = "browser:" + (request.page?.url ?? snapshot.windowTitle ?? snapshot.appName)
            if self.petViewModel.acknowledgment != nil {
                // A repeated finding for the same page is already visible.
                // Other findings remain retryable after the user acknowledges it.
                guard self.acknowledgmentContext == warningContext else { return false }
                let wasHidden = self.petViewModel.isAvatarHidden
                self.petViewModel.revealForWarning()
                if wasHidden, let target = self.acknowledgmentTarget { self.petViewModel.intervene(at: target) }
                return true
            }
            self.updateChatReport(verdict, source: .browserText, snapshot: snapshot)
            // Text-only browser protection needs no Screen Recording access.
            // If macOS withholds Chrome's window metadata, use the current
            // display center after verifying Chrome is foreground.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let fallback = screen.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) }
            let target = GuardianTarget.activeWindowCenter(expectedAppName: snapshot.appName) ?? fallback
            self.browserStatus = "Chrome warning delivered to Muse."
            guard self.presentVerdict(verdict, snapshot: snapshot, target: target,
                acknowledgmentID: request.id, acknowledgmentContext: warningContext) else { return false }
            if self.petViewModel.acknowledgment != nil { self.browserStatus = "Muse is waiting for Got it." }
            return true
        })
    private let screenReader = ScreenReader()
    private let screenshotCapture = ScreenshotCapture()
    private let riskAnalyzer = LocalRiskAnalyzer()
    private lazy var monitorLoop = MonitorLoop(screenReader: screenReader, riskAnalyzer: riskAnalyzer,
        screenshotCapture: screenshotCapture,
        chromeCoverage: { [weak self] source in await self?.hasFreshBrowserCoverage(source) ?? false },
        ignoredProcess: { UnrealCharacterRenderer.shared.ownsProcess($0) })
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
    private var inferenceActivityTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?
    private var chatRequestID: UUID?
    private var screenChatHistory = ScreenChatHistory()
    private lazy var browserProtection = GuardianProtectionActivity { [weak self] _ in self?.refreshOnDutyAppearance() }
    private init() {
        rememberChatApplication()
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular }
            .sink { [weak self] app in
                if !UnrealCharacterRenderer.shared.ownsProcess(app.processIdentifier) { self?.lastExternalApplication = app }
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
    }

    func startBrowserBridge() {
        do {
            try browserBridge.start { [weak self] request in
                guard let self else { return .failure(id: request.id, mode: request.mode, message: "Muse Guard is closing.") }
                if let controlReply = self.monitoringControl.handle(request) { return controlReply }
                if let contextReply = self.browserChatContext.handle(request) { return contextReply }
                if request.type == "assess", request.purpose != nil, !self.monitoringPaused { self.browserProtection.refreshFromAutomaticCheck() }
                return await self.browserAssessments.handle(request)
            }
            browserStatus = "Browser guard · local connection ready"
        } catch { browserStatus = "Browser guard unavailable: \(error.localizedDescription)" }
    }
    func stopBrowserBridge() { browserBridge.stop(); browserStatus = "Browser guard stopped" }

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
        if accessibilityTrusted { reconcileDesktopMonitoring() }
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
        if paused {
            stopMonitoring()
            browserAssessments.cancelAll()
            browserProtection.update(enabled: false)
        } else {
            reconcileDesktopMonitoring()
        }
        DispatchQueue.main.async { [weak self] in self?.refreshMonitoringStatus() }
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
                let interrupt = verdict.riskLevel == .high
                self.monitorStatus = "Last local check: \(verdict.riskLevel.rawValue)"
                self.logVerdict(verdict, source: screenshot ? .monitorScreenshot : .monitorText, snapshot: snapshot, includesScreenshot: screenshot, updatesChatContext: interrupt)
                if interrupt { return self.presentVerdict(verdict, snapshot: snapshot) }
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
        petViewModel.chatContextLabel = chatApplication().map { "Current app · \($0.localizedName ?? "selected app")" } ?? "Context refreshes when you ask"
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
        guard petViewModel.acknowledgment?.id == id else { return }
        // Acknowledgement dismisses this explanation, never the browser's
        // high-risk block. Native controls never grant a browser action.
        cancelDemo(); cancelChat()
        acknowledgmentContext = nil; acknowledgmentTarget = nil
        latestChatContext = nil
        screenChatHistory.reset()
        petViewModel.acknowledge(id: id)
        petViewModel.restoreVisibilityAfterWarning()
        browserStatus = "Warning acknowledged."
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
    private func chatApplication() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, isContextApplication(app) { return app }
        return lastExternalApplication.flatMap { $0.isTerminated ? nil : $0 }
    }
    private func isContextApplication(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier && app.activationPolicy == .regular &&
            !UnrealCharacterRenderer.shared.ownsProcess(app.processIdentifier)
    }
    private func isChrome(_ app: NSRunningApplication?) -> Bool { app?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true }
    private func hasFreshBrowserCoverage(_ source: ScreenSourceIdentity) async -> Bool {
        guard !monitoringPaused, !monitoringControl.syncPending, monitoringControl.browserConnected,
              browserProtection.isActive, source.bundleID?.hasPrefix("com.google.Chrome") == true else { return false }
        do {
            let fresh = try await browserChatContext.requestContext(timeout: 2)
            try Task.checkCancellation()
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == source.processID,
                  screenReader.sourceIdentity(for: app) == source else { return false }
            return ContextEvidence.visibleText(fresh.page.text).hasMeaningfulText
        } catch { return false }
    }

    private func desktopMonitoringMetadata() -> BrowserResponse.DesktopMonitoringMetadata {
        let counters = monitorLoop.diagnostics
        return .init(enabled: isMonitoring, accessibilityReady: AccessibilityPermissionController.isTrusted,
            screenCaptureReady: ScreenCapturePermissionController.isTrusted,
            textAnalyses: counters.textAnalyses, visualAnalyses: counters.visualAnalyses,
            windowCaptures: counters.windowCaptures, duplicateSkips: counters.duplicateSkips,
            browserCoverageSkips: counters.browserCoverageSkips, sourceChanges: counters.sourceChanges,
            lastMode: counters.lastMode, lastOutcome: counters.lastOutcome)
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
                snapshot = ScreenSnapshot(appName: name, windowTitle: fresh.page.title, text: fresh.page.text,
                    evidence: .visibleText(fresh.page.text), source: source)
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
            guard sourceIsCurrent(), latest.tabID == original.tabID, latest.documentID == original.documentID,
                  latest.page.url == original.page.url,
                  ContextEvidence.normalizedText(latest.page.text) == ContextEvidence.normalizedText(original.page.text) else {
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
        acknowledgmentID: String? = nil, acknowledgmentContext context: String? = nil) -> Bool {
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
        if petViewModel.acknowledgment != nil {
            guard verdict.riskLevel == .high, acknowledgmentContext == key else { return false }
            let wasHidden = petViewModel.isAvatarHidden
            petViewModel.revealForWarning()
            if wasHidden, let target = acknowledgmentTarget { petViewModel.intervene(at: target) }
            return true
        }
        cancelDemo()
        let risky = verdict.riskLevel == .medium || verdict.riskLevel == .high
        let pinned = risky || verdict.riskLevel == .unknown
        if verdict.riskLevel == .high {
            cancelChat()
            screenChatHistory.reset()
            if petViewModel.isAvatarHidden {
                petViewModel.revealForWarning()
            }
            let text = "\(verdict.summary)\n\(verdict.guidance)\nI’ll stay here until you choose Got it."
            guard petViewModel.showAcknowledgment(id: acknowledgmentID ?? UUID().uuidString, text: text,
                details: GuardianWarningDetails(summary: verdict.summary, guidance: verdict.guidance)) else { return false }
            acknowledgmentContext = key
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let verifiedTarget = snapshot.source.flatMap { source in
                source.windowID.flatMap { GuardianTarget.verifiedWindowCenter(windowID: $0, processID: source.processID) }
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
    deinit { inferenceActivityTask?.cancel() }
}

private enum ChatScreenError: Error { case changed }
