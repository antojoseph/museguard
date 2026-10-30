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
    @Published private(set) var settings = AppSettingsStore.load()
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitorStatus = "Monitoring paused"
    @Published private(set) var analysisLogs: [AnalysisLogEntry] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastMockResult: String?
    @Published private(set) var browserStatus = "Browser guard stopped"
    private let browserBridge = BrowserBridgeServer()
    private let browserChatContext = BrowserChatContextBroker()
    private lazy var browserAssessments: BrowserAssessmentCoordinator = BrowserAssessmentCoordinator(
        modelReady: { LocalModelService.shared.isReady },
        isDenied: { [weak self] snapshot in self?.isDenied(snapshot) ?? true },
        statusDetail: { [weak self] in self?.browserStatus ?? "Muse Guard is closing." },
        onProtectionChanged: { [weak self] enabled in self?.browserProtection.update(enabled:enabled) },
        onPresent: { [weak self] request, verdict, snapshot in
            guard let self else { return false }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
                self.browserStatus = "Chrome warning received; avatar stayed home because Chrome was not foreground."
                return false
            }
            guard !self.petViewModel.isAvatarHidden else {
                self.browserStatus = "Chrome warning received; Muse is hidden."
                return false
            }
            let warningContext = "browser:" + (request.page?.url ?? snapshot.windowTitle ?? snapshot.appName)
            if self.petViewModel.acknowledgment != nil {
                // A repeated finding for the same page is already visible.
                // Other findings remain retryable after the user acknowledges it.
                return verdict.riskLevel == .high && self.acknowledgmentContext == warningContext
            }
            if request.reason == "checking" {
                self.petViewModel.show("Let me check that before you go…\nI’ve paused this action while I check.", mood: .scanning,
                    clearAfter: request.mode == "vision" ? 65 : 35)
                self.browserPresentation = (request.id, self.petViewModel.message ?? "")
                if let kind = request.action?.kind, kind == "link" || kind == "submit" {
                    self.petViewModel.browserAction = BrowserAvatarAction(assessmentID: request.id, canContinue: false)
                }
                return true
            }
            self.logVerdict(verdict, source: request.mode == "vision" ? .browserVision : .browserText,
                snapshot: snapshot, includesScreenshot: request.mode == "vision")
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
            self.browserPresentation = (request.id, self.petViewModel.message ?? "")
            if verdict.riskLevel != .high, let kind = request.action?.kind, kind == "link" || kind == "submit" {
                self.petViewModel.browserAction = BrowserAvatarAction(assessmentID: request.id,
                    canContinue: self.browserAssessments.canContinue(assessmentID: request.id))
            }
            return true
        })
    private let screenReader = ScreenReader()
    private let screenshotCapture = ScreenshotCapture()
    private let riskAnalyzer = LocalRiskAnalyzer()
    private lazy var monitorLoop = MonitorLoop(screenReader: screenReader, riskAnalyzer: riskAnalyzer, screenshotCapture: screenshotCapture)
    private let settingsWindowController = SettingsWindowController()
    private let analysisLogsWindowController = AnalysisLogsWindowController()
    private var analysisTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var latestChatContext: RiskReportChatContext?
    private var lastMonitorErrorMessage: String?
    private var browserSubscriptions = Set<AnyCancellable>()
    private var visibleBrowserAssessmentID: String?
    private var browserPresentation: (id: String, message: String)?
    private var acknowledgmentContext: String?
    private var acknowledgmentTarget: CGPoint?
    private var browserActionExpiryTask: Task<Void, Never>?
    private var browserChoiceTask: Task<Void, Never>?
    private var inferenceActivityTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?
    private var chatRequestID: UUID?
    private var screenChatHistory = ScreenChatHistory()
    private lazy var browserProtection = GuardianProtectionActivity { UnrealCharacterRenderer.shared.setBrowserProtectionActive($0) }
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
        petViewModel.$browserAction.map { $0?.assessmentID }.removeDuplicates().sink { [weak self] next in
            guard let self else { return }
            if let previous = self.visibleBrowserAssessmentID, previous != next {
                self.browserAssessments.resolve(assessmentID: previous, continueOnce: false)
            }
            self.visibleBrowserAssessmentID = next
            self.browserActionExpiryTask?.cancel()
            guard let next else { return }
            self.browserActionExpiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled, let self, self.petViewModel.browserAction?.assessmentID == next else { return }
                self.dismissPetBubble()
            }
        }.store(in: &browserSubscriptions)
        petViewModel.$isAvatarHidden.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            guard let self else { return }
            self.cancelChat()
            self.screenChatHistory.reset()
            if self.petViewModel.browserAction != nil { self.dismissPetBubble() }
        }.store(in: &browserSubscriptions)
        petViewModel.$isChatOpen.removeDuplicates().filter { !$0 }.sink { [weak self] _ in
            self?.cancelChat()
        }.store(in: &browserSubscriptions)
    }

    /// The extension alone resumes the original action after rechecking its
    /// document and form. Native controls never open or submit a destination.
    func resolveBrowserAction(assessmentID: String, continueOnce: Bool) {
        guard let action = petViewModel.browserAction, action.assessmentID == assessmentID,
              !continueOnce || action.canContinue else { return }
        browserChoiceTask?.cancel()
        if !continueOnce {
            browserAssessments.resolve(assessmentID: assessmentID, continueOnce: false)
            dismissPetBubble()
            return
        }
        browserChoiceTask = Task { [weak self] in
            guard let self else { return }
            let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
            _ = chrome?.activate(options: [.activateIgnoringOtherApps])
            // Clicking Muse can activate the native panel. Publish the one-time
            // choice only after Chrome is foreground again; keep browser focus
            // checks intact rather than treating native clicks as an exception.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, self.petViewModel.browserAction?.assessmentID == assessmentID else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" {
                    self.browserAssessments.resolve(assessmentID: assessmentID, continueOnce: true)
                    self.dismissPetBubble()
                    return
                }
            }
            self.browserAssessments.resolve(assessmentID: assessmentID, continueOnce: false)
            self.dismissPetBubble()
        }
    }

    func startBrowserBridge() {
        do {
            try browserBridge.start { [weak self] request in
                guard let self else { return .failure(id: request.id, mode: request.mode, message: "Muse Guard is closing.") }
                if let contextReply = self.browserChatContext.handle(request) { return contextReply }
                if request.type == "assess", request.purpose != nil { self.browserProtection.refreshFromAutomaticCheck() }
                let response = await self.browserAssessments.handle(request)
                let closesPresentation = request.type == "cancel" ||
                    (request.type == "finish-checking" && ["pending", "stay"].contains(response.actionState ?? ""))
                if self.petViewModel.acknowledgment == nil, closesPresentation, let id = request.assessmentID,
                   self.petViewModel.browserAction?.assessmentID == id ||
                    (self.browserPresentation?.id == id && self.browserPresentation?.message == self.petViewModel.message) {
                    self.dismissPetBubble()
                }
                return response
            }
            browserStatus = "Browser guard · local connection ready"
        } catch { browserStatus = "Browser guard unavailable: \(error.localizedDescription)" }
    }
    func stopBrowserBridge() { browserBridge.stop(); browserStatus = "Browser guard stopped" }

    func toggleAvatarVisibility() {
        if petViewModel.isAvatarHidden {
            dismissPetBubble()
            petViewModel.isAvatarHidden = false
            if petViewModel.acknowledgment != nil, let target = acknowledgmentTarget { petViewModel.intervene(at: target) }
        } else {
            petViewModel.isAvatarHidden = true
            dismissPetBubble()
        }
    }

    func refreshAccessibilityStatus() { accessibilityTrusted = AccessibilityPermissionController.isTrusted }
    func refreshScreenCaptureStatus() { screenCaptureTrusted = ScreenCapturePermissionController.isTrusted }
    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityPermissionController.requestAccess()
        petViewModel.show(accessibilityTrusted ? "Accessibility is enabled. I can read focused-window text." : "Enable Muse Guard in Privacy & Security → Accessibility, then restart the app.", mood: .idle, clearAfter: 8)
    }
    func requestScreenCapturePermission() {
        screenCaptureTrusted = ScreenCapturePermissionController.requestAccess()
        petViewModel.show(screenCaptureTrusted ? "Screen Recording is enabled. Analysis stays on this Mac." : "Enable Muse Guard in Privacy & Security → Screen Recording, then restart the app.", mood: .idle, clearAfter: 8)
    }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func openScreenRecordingSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    func showSettings() { settingsWindowController.show(runtime: self) }
    func showAnalysisLogs() { analysisLogsWindowController.show(runtime: self) }
    func clearAnalysisLogs() { analysisLogs.removeAll() }

    func scanFocusedContext() {
        refreshAccessibilityStatus()
        guard accessibilityTrusted else { permissionMessage("Accessibility"); return }
        do {
            let snapshot = try screenReader.readFocusedContext()
            guard !isDenied(snapshot) else { showDenied(snapshot); return }
            petViewModel.show("\(snapshot.appName): \(snapshot.text.prefix(160))", clearAfter: 10)
        } catch { petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 8) }
    }
    func analyzeFocusedContext() {
        refreshAccessibilityStatus()
        guard accessibilityTrusted else { permissionMessage("Accessibility"); return }
        beginAnalysis(screenshot: false)
    }
    func analyzeScreenshot() {
        refreshScreenCaptureStatus()
        guard screenCaptureTrusted else { permissionMessage("Screen Recording"); return }
        beginAnalysis(screenshot: true)
    }
    private func beginAnalysis(screenshot: Bool) {
        guard modelReady() else { return }
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            self.isAnalyzing = true
            defer { self.isAnalyzing = false }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            var snapshot: ScreenSnapshot?
            do {
                let context = screenshot ? self.bestEffortContext() : try self.screenReader.readFocusedContext()
                snapshot = context
                guard !self.isDenied(context) else { self.showDenied(context); return }
                let image = screenshot ? try self.screenshotCapture.capture().dataURL : nil
                try await self.evaluate(context, image: image, source: screenshot ? .screenshot : .focusedWindow)
            } catch {
                guard !Task.isCancelled else { return }
                self.logError(error, source: screenshot ? .screenshot : .focusedWindow, snapshot: snapshot)
                self.petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 10)
            }
        }
    }
    private func evaluate(_ snapshot: ScreenSnapshot, image: String?, source: AnalysisLogSource, target: CGPoint? = nil) async throws {
        petViewModel.show("Checking locally with Muse Glimmer…", mood: .scanning)
        let verdict: RiskVerdict
        if let image { verdict = try await riskAnalyzer.analyze(snapshot: snapshot, screenshotDataURL: image, model: settings.modelName) }
        else { verdict = try await riskAnalyzer.analyze(snapshot: snapshot, model: settings.modelName) }
        try Task.checkCancellation()
        logVerdict(verdict, source: source, snapshot: snapshot, includesScreenshot: image != nil)
        presentVerdict(verdict, snapshot: snapshot, target: target)
    }
    func toggleMonitoring() { if isMonitoring { stopMonitoring(showMessage: true) } else { startMonitoring() } }
    func startMonitoring() {
        refreshScreenCaptureStatus()
        guard settings.monitoringConsentGranted else { petViewModel.show("Enable local monitoring in Settings first.", clearAfter: 8); showSettings(); return }
        guard screenCaptureTrusted else { permissionMessage("Screen Recording"); return }
        guard modelReady() else { return }
        lastMonitorErrorMessage = nil
        monitorLoop.start(model: settings.modelName, deniedAppNames: settings.deniedAppNames,
            onStatus: { [weak self] status in self?.monitorStatus = status.label },
            onVerdict: { [weak self] verdict, snapshot, screenshot in
                guard let self else { return }
                let interrupt = self.settings.alertSensitivity.shouldInterrupt(for: verdict.riskLevel)
                self.monitorStatus = "Last local check: \(verdict.riskLevel.rawValue)"
                self.logVerdict(verdict, source: .monitorScreenshot, snapshot: snapshot, includesScreenshot: screenshot, updatesChatContext: interrupt)
                if interrupt { self.presentVerdict(verdict, snapshot: snapshot) }
            },
            onError: { [weak self] error, snapshot in
                guard let self else { return }
                self.monitorStatus = "Local analysis unavailable"
                if error is ScreenshotCaptureError { self.stopMonitoring() }
                guard error.localizedDescription != self.lastMonitorErrorMessage else { return }
                self.lastMonitorErrorMessage = error.localizedDescription
                self.logError(error, source: .monitorScreenshot, snapshot: snapshot)
                self.petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 10)
            })
        isMonitoring = true
        petViewModel.show("Local monitoring started. Screen analysis stays on this Mac.", clearAfter: 6)
    }
    func stopMonitoring(showMessage: Bool = false) {
        monitorLoop.stop(); isMonitoring = false; monitorStatus = "Monitoring paused"
        if showMessage { petViewModel.show("Monitoring paused.", clearAfter: 4) }
    }
    func saveSettings(model: String, monitoringConsentGranted: Bool, alertSensitivity: AlertSensitivity, deniedAppNames: [String]) {
        let restart = isMonitoring
        stopMonitoring()
        settings = AppSettings(modelName: model.isEmpty ? AppSettings.defaultModel : model, monitoringConsentGranted: monitoringConsentGranted, alertSensitivity: alertSensitivity, deniedAppNames: deniedAppNames)
        AppSettingsStore.save(settings)
        petViewModel.show("Local model settings saved.", clearAfter: 4)
        if restart && monitoringConsentGranted { startMonitoring() }
    }
    func openPetChat() {
        rememberChatApplication()
        let explainsWarning = petViewModel.acknowledgment != nil || petViewModel.browserAction != nil ||
            (petViewModel.mood == .alert && petViewModel.message != nil)
        let explanation = explainsWarning ? latestChatContext.map { "Why I flagged it:\n\($0.summary)\n\nWhat to do:\n\($0.guidance)" } : nil
        petViewModel.openChat(seedText: explanation)
        if petViewModel.chatContextLabel == nil, let app = chatApplication() {
            petViewModel.chatContextLabel = "Current app · \(app.localizedName ?? "selected app")"
        }
    }
    func dismissPetBubble() {
        cancelChat()
        guard petViewModel.acknowledgment == nil else { return }
        demoTask?.cancel(); latestChatContext = nil
        browserChoiceTask?.cancel()
        browserPresentation = nil
        screenChatHistory.reset()
        petViewModel.dismissBubble()
    }
    func acknowledgeWarning(id: String) {
        guard petViewModel.acknowledgment?.id == id else { return }
        // Acknowledgement dismisses this explanation, never the browser's
        // high-risk block and never a Continue/allow grant.
        browserAssessments.resolve(assessmentID: id, continueOnce: false)
        demoTask?.cancel(); cancelChat(); browserChoiceTask?.cancel()
        acknowledgmentContext = nil; acknowledgmentTarget = nil
        latestChatContext = nil; browserPresentation = nil
        screenChatHistory.reset()
        petViewModel.acknowledge(id: id)
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
                    let fresh = try await self.captureChatContext(app:app)
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
                    screenContext:screen,history:scopedHistory,model:self.settings.modelName,
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
    private func chatWindow(for app: NSRunningApplication) -> (id:Int,title:String?)? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        guard let window = windows.first(where: { $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0 }),
              let id = window[kCGWindowNumber as String] as? Int else { return nil }
        return (id,window[kCGWindowName as String] as? String)
    }
    private func captureChatContext(app: NSRunningApplication?) async throws -> (context:ScreenChatContext,key:String,label:String) {
        guard let app, !app.isTerminated else { throw ScreenReaderError.noFrontmostApplication }
        let name = app.localizedName ?? "Current app"
        guard !isDenied(ScreenSnapshot(appName:name,windowTitle:nil,text:"")) else { throw ChatScreenError.denied }
        if isChrome(app) {
            let fresh = try await browserChatContext.requestContext()
            try Task.checkCancellation()
            guard chatApplication()?.processIdentifier == app.processIdentifier else { throw ChatScreenError.changed }
            let snapshot = ScreenSnapshot(appName:name,windowTitle:fresh.page.title,text:fresh.page.text)
            guard !isDenied(snapshot) else { throw ChatScreenError.denied }
            return (ScreenChatContext(snapshot:snapshot,sourceLabel:"Chrome extension · current visible page",url:fresh.page.url),
                "chrome:\(fresh.tabID):\(fresh.documentID):\(fresh.page.url)","Using Chrome · \(fresh.page.title)")
        }
        let beforeWindow = chatWindow(for:app)
        guard !isDenied(ScreenSnapshot(appName:name,windowTitle:beforeWindow?.title,text:"")) else { throw ChatScreenError.denied }
        var snapshot: ScreenSnapshot?
        if AccessibilityPermissionController.isTrusted { snapshot = try? screenReader.readContext(for:app) }
        if let snapshot, isDenied(snapshot) { throw ChatScreenError.denied }
        var image: String?
        if (snapshot?.text.count ?? 0) < 80, ScreenCapturePermissionController.isTrusted, let beforeWindow {
            image = try? screenshotCapture.capture(windowID:CGWindowID(beforeWindow.id)).dataURL
        }
        let afterWindow = chatWindow(for:app)
        guard chatApplication()?.processIdentifier == app.processIdentifier,
              beforeWindow?.id == afterWindow?.id, beforeWindow?.title == afterWindow?.title else { throw ChatScreenError.changed }
        guard snapshot != nil || image != nil else { throw ScreenReaderError.noReadableContent(name) }
        let evidence = snapshot ?? ScreenSnapshot(appName:name,windowTitle:beforeWindow?.title,text:"The attached image is the current application window.")
        return (ScreenChatContext(snapshot:evidence,sourceLabel:image == nil ? "Current application window text" : "Current application window screenshot",screenshotDataURL:image),
            "app:\(app.processIdentifier):\(beforeWindow?.id ?? -1)","Using \(name) · \(evidence.windowTitle ?? "current window")")
    }
    func previewGuardianIntervention() {
        guard petViewModel.acknowledgment == nil else { return }
        demoTask?.cancel()
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
        analysisTask?.cancel(); demoTask?.cancel()
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
    private func modelReady() -> Bool {
        guard LocalModelService.shared.isReady else {
            LocalModelService.shared.start()
            petViewModel.show("Muse Glimmer is starting on this Mac. Try again when the menu says it’s ready.", mood: .scanning, clearAfter: 8)
            return false
        }
        return true
    }
    private func bestEffortContext() -> ScreenSnapshot {
        if let snapshot = try? screenReader.readFocusedContext(maxCharacters: 3000) { return snapshot }
        return ScreenSnapshot(appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screen", windowTitle: nil, text: "Screenshot only; accessible text was unavailable.")
    }
    private func isDenied(_ snapshot: ScreenSnapshot) -> Bool { PrivacyFilter.isDenied(snapshot: snapshot, deniedAppNames: settings.deniedAppNames) }
    private func showDenied(_ snapshot: ScreenSnapshot) { petViewModel.show("Skipped \(snapshot.appName): it matches your privacy deny list.", clearAfter: 7) }
    private func permissionMessage(_ name: String) { petViewModel.show("Enable \(name) access from the menu, then restart Muse Guard.", mood: .scanning, clearAfter: 8) }
    @discardableResult
    private func presentVerdict(_ verdict: RiskVerdict, snapshot: ScreenSnapshot, target: CGPoint? = nil,
        acknowledgmentID: String? = nil, acknowledgmentContext context: String? = nil) -> Bool {
        let key = context ?? (snapshot.appName + ":" + (snapshot.windowTitle ?? ""))
        if petViewModel.acknowledgment != nil {
            return verdict.riskLevel == .high && acknowledgmentContext == key
        }
        demoTask?.cancel()
        let risky = verdict.riskLevel == .medium || verdict.riskLevel == .high
        let pinned = risky || verdict.riskLevel == .unknown
        if verdict.riskLevel == .high {
            cancelChat()
            let text = "\(verdict.summary)\n\(verdict.guidance)\nI’ll stay here until you choose Got it."
            guard petViewModel.showAcknowledgment(id: acknowledgmentID ?? UUID().uuidString, text: text,
                details: GuardianWarningDetails(summary: verdict.summary, guidance: verdict.guidance)) else { return false }
            acknowledgmentContext = key
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let point = target ?? GuardianTarget.activeWindowCenter(expectedAppName: snapshot.appName) ??
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
        if updatesChatContext && petViewModel.acknowledgment == nil { latestChatContext = RiskReportChatContext(sourceLabel: source.label, appName: snapshot.appName, windowTitle: snapshot.windowTitle, riskLevel: verdict.riskLevel, summary: verdict.summary, guidance: verdict.guidance, categories: verdict.categories) }
        appendLog(AnalysisLogEntry(timestamp: Date(), source: source, appName: snapshot.appName, windowTitle: snapshot.windowTitle, model: settings.modelName, includesScreenshot: includesScreenshot, verdict: verdict, errorMessage: nil))
    }
    private func logError(_ error: Error, source: AnalysisLogSource, snapshot: ScreenSnapshot?) {
        appendLog(AnalysisLogEntry(timestamp: Date(), source: source, appName: snapshot?.appName ?? source.label, windowTitle: snapshot?.windowTitle, model: settings.modelName, includesScreenshot: false, verdict: nil, errorMessage: error.localizedDescription))
    }
    private func appendLog(_ entry: AnalysisLogEntry) { analysisLogs.insert(entry, at: 0); if analysisLogs.count > 200 { analysisLogs.removeLast() } }
    deinit { inferenceActivityTask?.cancel() }
}

private enum ChatScreenError: Error { case changed, denied }
