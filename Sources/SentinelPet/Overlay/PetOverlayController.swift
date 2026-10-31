import AppKit
import SwiftUI
import Combine

@MainActor
final class PetOverlayController {
    private var panel: PetPanel?
    private let viewModel: PetViewModel
    private var subscriptions = Set<AnyCancellable>()
    private var motion: Task<Void, Never>?
    private var pointerTimer: Timer?
    private var home: CGPoint?
    private var moving = false
    private var returning = false
    private var headingToBed = false
    private var bedtimeJourney: (from:CGPoint,to:CGPoint,start:Date,duration:Double)?
    private var away = false
    private var desktopPanel: PetPanel?
    private let desktopPresentation = GuardianDesktopPresentation()
    private var outwardScene: GuardianDesktopScene?
    private var pendingReturn = false
    private var messagePanel: PetPanel?
    private var predictionPanel: PetPanel?
    private var predictionSilhouette: CGRect?
    private var predictionSilhouetteSequence: UInt32?
    private var predictionSilhouetteIsDesktop: Bool?
    private var predictionSilhouetteSampledAt = Date.distantPast
    private var messageSize = CGSize(width:240,height:80)
    private var placementTask: Task<Void,Never>?
    private var lastAutoMove = Date()
    private var lastActivitySample = Date.distantPast
    private var recentPointers: [(CGPoint,Date)] = []
    private var activityBounds: [CGRect] = []
    private var messageAvatarRect = CGRect.null
    private var messagePoseRect = CGRect.null
    private var messageScreenRect = CGRect.null
    private var messageDesiredSize = CGSize.zero
    private var dragStartAnchor: CGPoint?
    private var queuedTarget: CGPoint?
    private var homeAnchor: CGPoint {
        guard let panel else { return .zero }
        return CGPoint(x: panel.frame.minX + 110,
                       y: panel.frame.minY + 110)
    }
    private var dragActions: GuardianDragActions {
        GuardianDragActions(begin: { [weak self] in self?.beginDragging() ?? false },
                            move: { [weak self] in self?.drag(by: $0) },
                            end: { [weak self] in self?.endDragging() })
    }

    init(viewModel: PetViewModel) { self.viewModel = viewModel }
    func show() {
        let hosting = NSHostingView(rootView: PetRootView(dragActions: dragActions))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: MuseLayout.panelSize)
        let panel = PetPanel(contentRect: hosting.frame)
        panel.contentView = hosting
        self.panel = panel
        let defaults = UserDefaults.standard
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let saved: CGPoint
        if let text = defaults.string(forKey: "museHomeAnchor") { saved = NSPointFromString(text) }
        else if let text = defaults.string(forKey: "museHomeOrigin") {
            let old = NSPointFromString(text)
            saved = CGPoint(x: old.x + 118, y: old.y + 118)
        } else { saved = CGPoint(x: visible.minX + 134, y: visible.minY + 134) }
        applyHomeAnchor(saved)
        let message = PetPanel(contentRect: CGRect(origin:.zero,size:messageSize), acceptsKeyboard: true)
        let messageHost = GuardianMessageHostingView(rootView: GuardianMessageView(viewModel:viewModel, onSize: { [weak self] size in
            guard let self, size.width > 20, size.height > 20 else { return }
            let rounded = CGSize(width:ceil(size.width),height:ceil(size.height))
            guard rounded != self.messageSize else { return }
            self.messageSize = rounded
            DispatchQueue.main.async { [weak self] in self?.updateMessagePanel() }
        }))
        // AppKit owns the panel's complete frame. Intrinsic SwiftUI sizing
        // otherwise grows it right/down after edge placement, then fights the
        // placement timer on each layout pass.
        messageHost.sizingOptions = []
        messageHost.autoresizingMask = [.width,.height]
        message.contentView = messageHost
        message.title = "Muse Guard Chat"
        message.identifier = NSUserInterfaceItemIdentifier(WatchedApplicationPolicy.chatWindowIdentifier)
        messagePanel = message
        let prediction = PetPanel(contentRect: CGRect(origin: .zero, size: PredictionDebugPlacement.size))
        let predictionHost = NSHostingView(rootView: PredictionDebugView(viewModel: viewModel))
        predictionHost.sizingOptions = []
        predictionHost.autoresizingMask = [.width, .height]
        prediction.contentView = predictionHost
        prediction.title = "Muse Model Activity"
        prediction.identifier = NSUserInterfaceItemIdentifier("muse-prediction-debug")
        prediction.ignoresMouseEvents = true
        predictionPanel = prediction
        NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            guard let self, !self.away else { return }
            self.applyHomeAnchor(self.homeAnchor,persist:false)
        }.store(in:&subscriptions)
        viewModel.$automaticallyPositions.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.lastAutoMove = .distantPast
            if !enabled { self.placementTask?.cancel(); self.placementTask = nil; self.panel?.alphaValue = 1 }
        }.store(in:&subscriptions)
        viewModel.$isAvatarHidden.removeDuplicates().sink { [weak self] hidden in
            self?.setHidden(hidden)
        }.store(in: &subscriptions)
        viewModel.$intervention.dropFirst().sink { [weak self] event in
            guard let self else { return }
            if let event { self.intervene(at: event.target) } else { self.returnHome() }
        }.store(in: &subscriptions)
        viewModel.$isChatOpen.sink { [weak self] open in
            guard let self, !self.moving else { return }
            if open {
                UnrealCharacterRenderer.shared.wakeForInteraction()
                self.placementTask?.cancel(); self.placementTask = nil; self.panel?.alphaValue = 1
                UnrealCharacterRenderer.shared.state = "explain"
            }
            else if !self.away { UnrealCharacterRenderer.shared.state = self.viewModel.mood == .scanning ? "scanning" : "idle" }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateMessagePanel()
                if open, !self.viewModel.isAvatarHidden { self.messagePanel?.makeKey() }
            }
        }.store(in: &subscriptions)
        viewModel.$mood.dropFirst().sink { [weak self] mood in
            guard let self else { return }
            if mood == .scanning { self.cancelBedtime() }
            guard !self.away, !self.moving, !self.viewModel.isChatOpen else { return }
            UnrealCharacterRenderer.shared.state = mood == .scanning ? "scanning" : "idle"
        }.store(in: &subscriptions)
        UnrealCharacterRenderer.shared.$previewState.dropFirst().sink { [weak self] preview in
            guard let self,self.headingToBed,preview != "live" else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.headingToBed else { return }
                self.cancelBedtime();UnrealCharacterRenderer.shared.previewState=preview
            }
        }.store(in:&subscriptions)
        UnrealCharacterRenderer.shared.$latestFrame.compactMap { $0?.isDesktopScene }.removeDuplicates().sink { [weak self] onStage in
            guard let self, !self.viewModel.isAvatarHidden else { return }
            if onStage {
                self.panel?.orderOut(nil)
                self.desktopPanel?.orderFrontRegardless()
            } else {
                self.desktopPanel?.orderOut(nil)
                self.panel?.orderFrontRegardless()
            }
        }.store(in: &subscriptions)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHitTesting()
                self?.updateMessagePanel()
                self?.updatePredictionPanel()
                self?.considerAutomaticPlacement()
            }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        UnrealCharacterRenderer.shared.prepareSleep = { [weak self] in self?.beginBedtime() }
        UnrealCharacterRenderer.shared.start()
        viewModel.greet()
    }
    #if MUSE_DEVELOPMENT
    func showChatCornerCheck() {
        guard BuildConfiguration.visualTestingEnabled,
              let screen=NSScreen.main?.visibleFrame else { return }
        applyHomeAnchor(CGPoint(x:screen.maxX,y:screen.minY),persist:false)
        viewModel.openChat(seedText:"Corner layout check. The close button and message field should stay fully visible, and closing should leave the box closed.")
    }
    #endif
    private func intervene(at target: CGPoint) {
        cancelBedtime()
        guard let panel, !viewModel.isAvatarHidden else { return }
        if viewModel.acknowledgment != nil {
            pendingReturn = false
            if away && returning { _ = holdAcknowledgmentInFront(); return }
        }
        if dragStartAnchor != nil { queuedTarget = target; return }
        // A second verdict updates the warning without replaying a jump in place.
        guard !away else { return }
        placementTask?.cancel(); placementTask = nil; panel.alphaValue = 1
        motion?.cancel()
        home = panel.frame.origin
        away = true
        moving = true
        returning = false
        pendingReturn = false
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(target) } ?? panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        let homeAnchor = self.homeAnchor
        let viewport = NSScreen.screens.reduce(screen?.frame ?? visible) { $0.union($1.frame) }
        let destination = CGPoint(x: min(max(target.x, visible.minX + 200), visible.maxX - 200),
                                  y: min(max(target.y, visible.minY + 190), visible.maxY - 220))
        let scene = GuardianDesktopScene(viewport: viewport, from: homeAnchor, to: destination, fromScale: 1, toScale: 1)
        outwardScene = scene
        viewModel.interventionAnchor = scene.to
        let wakeDelay = UnrealCharacterRenderer.shared.wakeForInteraction()
        motion = Task { [weak self] in
            guard let self else { return }
            if wakeDelay > 0 { try? await Task.sleep(nanoseconds:UInt64(wakeDelay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self.prepareDesktop(scene)
            // Swap surfaces only after a frame from the new camera arrives.
            guard await self.waitForDesktopFrame(true) else { if !Task.isCancelled { self.finishAtHome() }; return }
            await self.performLeap(scene, state: "jump")
            guard !Task.isCancelled else { return }
            self.moving = false
            UnrealCharacterRenderer.shared.state = self.viewModel.isChatOpen ? "explain" : "stop"
            self.desktopPresentation.showsMessage = true
            self.recordMotion("stop")
            if self.pendingReturn { self.returnHome() }
        }
    }
    private func prepareDesktop(_ scene: GuardianDesktopScene) {
        let renderer = UnrealCharacterRenderer.shared
        desktopPresentation.size = scene.viewport.size
        desktopPresentation.showsMessage = false
        if desktopPanel == nil {
            let stage = PetPanel(contentRect: scene.viewport)
            stage.isMovableByWindowBackground = false
            stage.ignoresMouseEvents = true
            stage.contentView = NSHostingView(rootView: GuardianDesktopView(presentation: desktopPresentation, dragActions: dragActions))
            desktopPanel = stage
        }
        desktopPanel?.setFrame(scene.viewport, display: false)
        renderer.configureDesktop(scene, state: "prepare")
    }
    private func returnHome() {
        if holdAcknowledgmentInFront() { return }
        if headingToBed { cancelBedtime();return }
        guard away, let scene = outwardScene else { UnrealCharacterRenderer.shared.state = "idle"; return }
        // Finish the landing or the user's drag before returning.
        if dragStartAnchor != nil { pendingReturn = true; return }
        if moving { pendingReturn = true; return }
        motion?.cancel()
        moving = true
        returning = true
        desktopPresentation.showsMessage = false
        motion = Task { [weak self] in
            guard let self else { return }
            UnrealCharacterRenderer.shared.configureDesktop(scene.reversed, state: "prepare")
            await self.performLeap(scene.reversed, state: "return")
            guard !Task.isCancelled else { return }
            if self.holdAcknowledgmentInFront() { return }
            let renderer = UnrealCharacterRenderer.shared
            renderer.configureDesktop(nil, state: "idle")
            _ = await self.waitForDesktopFrame(false)
            guard !Task.isCancelled else { return }
            self.finishAtHome()
        }
    }
    private func performLeap(_ scene: GuardianDesktopScene, state: String) async {
        let renderer = UnrealCharacterRenderer.shared
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let direction = GuardianJumpTiming.direction(from: scene.from, to: scene.to)
        renderer.animate("notice", duration: reduced ? 0.08 : GuardianJumpTiming.anticipation, direction: direction)
        try? await Task.sleep(nanoseconds: UInt64((reduced ? 0.08 : GuardianJumpTiming.anticipation) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        let duration = reduced ? 0.12 : GuardianJumpTiming.flight
        renderer.animate(state, duration: duration, direction: direction)
        recordMotion(state + "-start")
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        guard !Task.isCancelled else { return }
        recordMotion(state + "-end")
        renderer.animate("land", duration: reduced ? 0.08 : GuardianJumpTiming.landing)
        try? await Task.sleep(nanoseconds: UInt64((reduced ? 0.08 : GuardianJumpTiming.landing) * 1_000_000_000))
    }
    private func waitForDesktopFrame(_ expected: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !Task.isCancelled && Date() < deadline {
            if UnrealCharacterRenderer.shared.latestFrame?.isDesktopScene == expected { return true }
            try? await Task.sleep(nanoseconds: 16_666_667)
        }
        return false
    }
    private func finishAtHome() {
        viewModel.interventionAnchor = nil
        if holdAcknowledgmentInFront() { return }
        UnrealCharacterRenderer.shared.desktopScene = nil
        UnrealCharacterRenderer.shared.state = "idle"
        desktopPanel?.orderOut(nil)
        if !viewModel.isAvatarHidden { panel?.orderFrontRegardless() }
        desktopPresentation.showsMessage = false
        away = false; moving = false; returning = false; pendingReturn = false
        recordMotion("home")
    }
    @discardableResult
    private func holdAcknowledgmentInFront() -> Bool {
        guard viewModel.acknowledgment != nil else { return false }
        pendingReturn = false
        motion?.cancel(); motion = nil
        moving = false; returning = false
        if let scene = outwardScene {
            UnrealCharacterRenderer.shared.configureDesktop(scene, state: viewModel.isChatOpen ? "explain" : "stop")
            desktopPresentation.showsMessage = true
        }
        return true
    }
    private func applyHomeAnchor(_ anchor: CGPoint, persist: Bool = true) {
        guard let panel,
              let screen = GuardianPlacement.nearestScreen(to: anchor, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        let placement = GuardianPlacement(anchor: anchor, screen: screen)
        panel.setFrameOrigin(placement.origin)
        home = placement.origin
        updateMessagePanel()
        if persist {
            UserDefaults.standard.set(NSStringFromPoint(placement.anchor), forKey: "museHomeAnchor")
            UserDefaults.standard.set(NSStringFromPoint(placement.origin), forKey: "museHomeOrigin")
        }
    }
    private func setHidden(_ hidden: Bool) {
        if hidden {
            cancelBedtime()
            placementTask?.cancel(); placementTask = nil; panel?.alphaValue = 1
            motion?.cancel(); motion = nil
            viewModel.interventionAnchor = nil
            away = false; moving = false; returning = false; pendingReturn = false; queuedTarget = nil
            dragStartAnchor = nil
            desktopPresentation.showsMessage = false
            panel?.orderOut(nil); desktopPanel?.orderOut(nil); messagePanel?.orderOut(nil); predictionPanel?.orderOut(nil)
            UnrealCharacterRenderer.shared.configureDesktop(nil, state: "idle")
            recordMotion("hidden")
        } else {
            applyHomeAnchor(homeAnchor)
            if UnrealCharacterRenderer.shared.latestFrame?.isDesktopScene != true { panel?.orderFrontRegardless() }
            recordMotion("shown")
        }
    }
    private func beginDragging() -> Bool {
        guard !moving, !viewModel.isAvatarHidden else { return false }
        placementTask?.cancel(); placementTask = nil; panel?.alphaValue = 1
        UnrealCharacterRenderer.shared.wakeForInteraction()
        if !away { UnrealCharacterRenderer.shared.state = "idle" }
        viewModel.automaticallyPositions = false
        dragStartAnchor = away ? outwardScene?.to : homeAnchor
        recordMotion("drag-start")
        return dragStartAnchor != nil
    }
    private func drag(by delta: CGSize) {
        guard let start = dragStartAnchor else { return }
        let requested = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        if away, let scene = outwardScene {
            let screen = GuardianPlacement.nearestScreen(to: requested, screens: NSScreen.screens.map(\.visibleFrame)) ?? scene.viewport
            let anchor = GuardianPlacement(anchor:requested,screen:screen).anchor
            let updated = GuardianDesktopScene(viewport: scene.viewport, from: scene.from, to: anchor, fromScale: scene.fromScale, toScale: scene.toScale)
            outwardScene = updated
            UnrealCharacterRenderer.shared.desktopScene = updated
        } else { applyHomeAnchor(requested, persist: false) }
    }
    private func endDragging() {
        guard dragStartAnchor != nil else { return }
        dragStartAnchor = nil
        if away, let scene = outwardScene {
            applyHomeAnchor(scene.to)
            outwardScene = GuardianDesktopScene(viewport: scene.viewport, from: homeAnchor, to: scene.to, fromScale: 1, toScale: scene.toScale)
            UnrealCharacterRenderer.shared.desktopScene = outwardScene
        } else { applyHomeAnchor(homeAnchor) }
        recordMotion("drag-end")
        if pendingReturn { returnHome() }
        else if let target = queuedTarget { queuedTarget = nil; intervene(at: target) }
    }

    private var visibleAvatarRect: CGRect {
        if away, let scene = outwardScene {
            let r = MuseLayout.visibleCharacter
            let scale = CGFloat(scene.toScale)
            return CGRect(x:scene.to.x+(r.minX-110)*scale, y:scene.to.y+(r.minY-110)*scale,
                          width:r.width*scale,height:r.height*scale)
        }
        guard let panel else { return .zero }
        return MuseLayout.visibleCharacter.offsetBy(dx:panel.frame.minX,dy:panel.frame.minY)
    }
    private var messageBodyRect: CGRect {
        var body = visibleAvatarRect
        if let frame = UnrealCharacterRenderer.shared.latestFrame {
            let drawRect: CGRect?
            if away, frame.isDesktopScene, let stage = desktopPanel {
                drawRect = (frame.desktopRect ?? CGRect(origin:.zero,size:stage.frame.size))
                    .offsetBy(dx:stage.frame.minX,dy:stage.frame.minY)
            } else if !away, !frame.isDesktopScene, let panel {
                drawRect = MuseLayout.characterRect.offsetBy(dx:panel.frame.minX,dy:panel.frame.minY)
            } else { drawRect = nil }
            if let drawRect, let rendered = frame.silhouette(in:drawRect) { body = body.union(rendered) }
        }
        // Leave room for fur and breathing outside the conservative pose.
        return body.insetBy(dx:-12,dy:-12)
    }
    private func updateMessagePanel() {
        guard let messagePanel else { return }
        guard !viewModel.isAvatarHidden, !moving, dragStartAnchor == nil, placementTask == nil,
              (viewModel.isChatOpen || viewModel.bubbleText != nil), (!away || desktopPresentation.showsMessage) else {
            messagePanel.orderOut(nil); return
        }
        let pose = visibleAvatarRect
        guard let screen = GuardianPlacement.nearestScreen(to:CGPoint(x:pose.midX,y:pose.midY),screens:NSScreen.screens.map(\.visibleFrame)) else { return }
        // Do not make a bubble dodge the cursor while someone is trying to
        // read/click it. Reflow only when its content size or avatar changes.
        let desiredSize=viewModel.isChatOpen ? MuseLayout.chatPanelSize : messageSize
        if messagePanel.isVisible, messageDesiredSize == desiredSize,
           messagePoseRect == pose, messageScreenRect == screen, screen.contains(messagePanel.frame) {
            return
        }
        let body = messageBodyRect
        // Reserve one pose envelope while reading. Sampling the pixels only
        // when placement changes keeps breathing smooth and the card still.
        let avatar = messagePanel.isVisible && messagePoseRect == pose
            ? messageAvatarRect.union(body) : body
        let frame = GuardianPlacement.messageFrame(size:desiredSize,avatar:avatar,screen:screen,obstacles:activityBounds,pointer:NSEvent.mouseLocation,
            preferSide:viewModel.acknowledgment != nil || away)
        if messagePanel.frame != frame {
            messagePanel.setFrame(frame,display:false)
            messagePanel.contentView?.frame=CGRect(origin:.zero,size:frame.size)
        }
        messageAvatarRect = avatar
        messagePoseRect = pose
        messageScreenRect = screen
        messageDesiredSize = desiredSize
        if !messagePanel.isVisible { messagePanel.orderFrontRegardless() }
    }
    private func updatePredictionPanel() {
        guard let predictionPanel else { return }
        let renderer = UnrealCharacterRenderer.shared
        guard viewModel.showsPredictionDebug, !viewModel.isAvatarHidden,
              renderer.isReady, let frame = renderer.latestFrame else {
            predictionPanel.orderOut(nil); return
        }
        let drawRect: CGRect
        if frame.isDesktopScene, let stage = desktopPanel, stage.isVisible, let rect = frame.desktopRect {
            drawRect = rect.offsetBy(dx: stage.frame.minX, dy: stage.frame.minY)
        } else if !frame.isDesktopScene, let panel, panel.isVisible {
            drawRect = MuseLayout.characterRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        } else {
            predictionPanel.orderOut(nil); return
        }
        // The frame's draw rectangle follows every rendered leap/step. Refine
        // its visible silhouette at most four times a second, reusing that
        // normalized geometry between frames instead of scanning at 30 Hz.
        let now = Date()
        if predictionSilhouetteIsDesktop != frame.isDesktopScene ||
            predictionSilhouetteSequence != frame.sequence && now.timeIntervalSince(predictionSilhouetteSampledAt) >= 0.25 {
            predictionSilhouette = frame.silhouette
            predictionSilhouetteSequence = frame.sequence
            predictionSilhouetteIsDesktop = frame.isDesktopScene
            predictionSilhouetteSampledAt = now
        }
        guard let normalized = predictionSilhouette else { predictionPanel.orderOut(nil); return }
        let avatar = CGRect(x: drawRect.minX + normalized.minX * drawRect.width,
            y: drawRect.minY + normalized.minY * drawRect.height,
            width: normalized.width * drawRect.width, height: normalized.height * drawRect.height)
        guard let screen = GuardianPlacement.nearestScreen(to: CGPoint(x: avatar.midX, y: avatar.midY),
            screens: NSScreen.screens.map(\.visibleFrame)) else {
            predictionPanel.orderOut(nil); return
        }
        let obstacles = messagePanel.flatMap { $0.isVisible ? [$0.frame] : nil } ?? []
        guard let placement = PredictionDebugPlacement.frame(avatar: avatar, screen: screen, avoiding: obstacles) else {
            predictionPanel.orderOut(nil); return
        }
        if predictionPanel.frame != placement {
            predictionPanel.setFrame(placement, display: false)
            predictionPanel.contentView?.frame = CGRect(origin: .zero, size: placement.size)
        }
        predictionPanel.alphaValue = frame.isDesktopScene ? 1 : (panel?.alphaValue ?? 1)
        // A separate panel cannot intercept clicks or become the key window.
        // Its position never constrains Muse or shifts an active warning.
        if !predictionPanel.isVisible { predictionPanel.orderFrontRegardless() }
    }
    private func considerAutomaticPlacement() {
        let now = Date()
        guard now.timeIntervalSince(lastActivitySample) >= 1 else { return }
        lastActivitySample = now
        guard !viewModel.isAvatarHidden else { return }
        if UnrealCharacterRenderer.shared.frameIsSleeping,
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) < 1.5 {
            wakeForUserActivity()
        }
        let pointer = NSEvent.mouseLocation
        recentPointers.append((pointer,now))
        recentPointers.removeAll { now.timeIntervalSince($0.1)>30 }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            activityBounds = GuardianActivityGeometry.activeWindowBounds()
        }
        guard !UnrealCharacterRenderer.shared.frameIsSleeping,
              UnrealCharacterRenderer.shared.state != "sleep", UnrealCharacterRenderer.shared.state != "settle",
              UnrealCharacterRenderer.shared.previewState != "sleep",
              viewModel.automaticallyPositions, !away, !moving, dragStartAnchor == nil,
              placementTask == nil, !viewModel.isChatOpen, viewModel.message == nil,
              NSEvent.pressedMouseButtons == 0, now.timeIntervalSince(lastAutoMove)>12,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !visibleAvatarRect.insetBy(dx:-18,dy:-18).contains(pointer),
              let screen = GuardianPlacement.nearestScreen(to:homeAnchor,screens:NSScreen.screens.map(\.visibleFrame)),
              let destination = GuardianAutoPlacement.destination(current:homeAnchor,screen:screen,obstacles:activityBounds,recentPointers:recentPointers.filter { now.timeIntervalSince($0.1)<=8 }.map(\.0)) else { return }
        lastAutoMove = now
        placementTask = Task { [weak self] in
            guard let self else { return }
            // Quietly yield space; reserve the dramatic leap for actual warnings.
            let steps = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 6
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                self.panel?.alphaValue = 1-CGFloat(i)/CGFloat(steps)
                try? await Task.sleep(nanoseconds:25_000_000)
            }
            guard !Task.isCancelled else { return }
            self.applyHomeAnchor(destination,persist:false)
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                self.panel?.alphaValue = CGFloat(i)/CGFloat(steps)
                try? await Task.sleep(nanoseconds:25_000_000)
            }
            guard !Task.isCancelled else { return }
            self.placementTask = nil
            self.recordMotion("auto-place")
        }
    }

    private func wakeForUserActivity() {
        let renderer = UnrealCharacterRenderer.shared
        guard !viewModel.isAvatarHidden,
              viewModel.acknowledgment == nil, !away, !viewModel.isChatOpen else { return }
        cancelBedtime()
        guard !moving, dragStartAnchor == nil, renderer.previewState == "live" else { return }
        let delay = renderer.wakeForInteraction()
        if delay == 0 { renderer.state = viewModel.mood == .scanning ? "scanning" : "idle"; return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
            guard let self, !self.viewModel.isAvatarHidden,
                  !self.away, !self.moving, !self.viewModel.isChatOpen, self.viewModel.acknowledgment == nil,
                  renderer.state == "wake" else { return }
            renderer.state = self.viewModel.mood == .scanning ? "scanning" : "idle"
        }
    }
    private func beginBedtime() {
        let renderer=UnrealCharacterRenderer.shared
        guard !viewModel.isAvatarHidden,!away,!moving,dragStartAnchor == nil,
              !viewModel.isChatOpen,viewModel.message == nil,NSEvent.pressedMouseButtons == 0,
              !visibleAvatarRect.insetBy(dx:-18,dy:-18).contains(NSEvent.mouseLocation),
              let screen=GuardianPlacement.nearestScreen(to:homeAnchor,screens:NSScreen.screens.map(\.visibleFrame)) else {
            renderer.deferNap();return
        }
        placementTask?.cancel();placementTask=nil;panel?.alphaValue=1
        motion?.cancel();headingToBed=true;moving=true
        let start=homeAnchor
        var obstacles=GuardianActivityGeometry.activeWindowBounds()
        // Keep recent activity useful while the user previews bedtime in Studio.
        if obstacles.isEmpty { obstacles=activityBounds }
        let destination = viewModel.automaticallyPositions ?
            GuardianSleepPlacement.destination(current:start,screen:screen,obstacles:obstacles,recentPointers:recentPointers.map(\.0)+[NSEvent.mouseLocation]) : start
        let reduced=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wakeDelay=renderer.wakeForInteraction()
        motion=Task { [weak self] in
            guard let self else { return }
            if wakeDelay>0 { try? await Task.sleep(nanoseconds:UInt64(wakeDelay*1_000_000_000)) }
            guard !Task.isCancelled else { return }
            renderer.animate("yawn",duration:2.8)
            self.recordMotion("bedtime-yawn")
            if !reduced { try? await Task.sleep(nanoseconds:2_800_000_000) }
            guard !Task.isCancelled else { return }
            if !reduced {
                let viewport=NSScreen.screens.reduce(screen) { $0.union($1.frame) }
                for leg in GuardianBedtimeRoute.legs(from:start,to:destination) {
                    guard !Task.isCancelled else { return }
                    let scene=GuardianDesktopScene(viewport:viewport,from:leg.from,to:leg.to,fromScale:1,toScale:1)
                    self.prepareDesktop(scene)
                    guard await self.waitForDesktopFrame(true),!Task.isCancelled else { self.cancelBedtime();return }
                    let duration=min(20,leg.duration)
                    self.bedtimeJourney=(leg.from,leg.to,Date(),duration)
                    renderer.animate(leg.animation,duration:duration,direction:GuardianJumpTiming.direction(from:leg.from,to:leg.to))
                    self.recordMotion("bedtime-"+leg.animation)
                    try? await Task.sleep(nanoseconds:UInt64(duration*1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.applyHomeAnchor(leg.to,persist:false)
                }
            }
            self.applyHomeAnchor(destination,persist:false)
            renderer.configureDesktop(nil,state:"settle")
            _ = await self.waitForDesktopFrame(false)
            guard !Task.isCancelled else { return }
            self.bedtimeJourney=nil;self.headingToBed=false;self.moving=false
            self.recordMotion("bedtime-settle")
        }
    }
    private func cancelBedtime() {
        guard headingToBed else { return }
        motion?.cancel();motion=nil
        if let journey=bedtimeJourney {
            let t=min(1,max(0,Date().timeIntervalSince(journey.start)/journey.duration))
            applyHomeAnchor(CGPoint(x:journey.from.x+(journey.to.x-journey.from.x)*t,
                                    y:journey.from.y+(journey.to.y-journey.from.y)*t),persist:false)
        }
        bedtimeJourney=nil;headingToBed=false;moving=false
        UnrealCharacterRenderer.shared.configureDesktop(nil,state:"idle")
    }

    private func recordMotion(_ phase: String) {
        #if MUSE_DEVELOPMENT
        guard BuildConfiguration.visualTestingEnabled, let panel else { return }
        let record: [String: Any] = ["phase": phase, "x": panel.frame.minX, "y": panel.frame.minY, "homeX": home?.x ?? 0, "homeY": home?.y ?? 0, "time": Date().timeIntervalSince1970, "desktopScene": UnrealCharacterRenderer.shared.latestFrame?.isDesktopScene ?? false, "anchorX": homeAnchor.x, "anchorY": homeAnchor.y, "hidden": viewModel.isAvatarHidden, "automatic": viewModel.automaticallyPositions]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muse-motion-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) { _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close() }
        #endif
    }

    private func updateHitTesting() {
        guard let panel, !viewModel.isAvatarHidden, NSEvent.pressedMouseButtons == 0 else { return }
        guard UnrealCharacterRenderer.shared.isReady, let frame = UnrealCharacterRenderer.shared.latestFrame else {
            panel.ignoresMouseEvents = true; desktopPanel?.ignoresMouseEvents = true
            return
        }
        if let stage = desktopPanel, frame.isDesktopScene {
            let p = CGPoint(x: NSEvent.mouseLocation.x - stage.frame.minX, y: NSEvent.mouseLocation.y - stage.frame.minY)
            let rect = frame.desktopRect ?? CGRect(origin: .zero, size: stage.frame.size)
            stage.ignoresMouseEvents = moving || !rect.contains(p) || !characterHasPixel(in: frame.image, at: p, rect: rect)
            return
        }
        let p = CGPoint(x: NSEvent.mouseLocation.x - panel.frame.minX, y: NSEvent.mouseLocation.y - panel.frame.minY)
        let onCharacter = MuseLayout.characterRect.contains(p) && characterHasPixel(in: frame.image, at:p)
        panel.ignoresMouseEvents = !onCharacter
    }
    private func characterHasPixel(in image: CGImage, at p: CGPoint, rect: CGRect = MuseLayout.characterRect) -> Bool {
        guard let bytes = image.dataProvider?.data, let pointer = CFDataGetBytePtr(bytes) else { return false }
        let x = min(image.width-1,max(0,Int((p.x-rect.minX)/rect.width*CGFloat(image.width))))
        let y = min(image.height-1,max(0,Int((1-(p.y-rect.minY)/rect.height)*CGFloat(image.height))))
        return pointer[y*image.bytesPerRow+x*4+3] > 24
    }
    deinit {
        motion?.cancel(); placementTask?.cancel(); pointerTimer?.invalidate()
    }
}

/// A warning is normally above another app's active window. Its first click
/// must reach the chosen control, rather than only activating the panel.
private final class GuardianMessageHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
