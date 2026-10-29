import AppKit
import Combine

/// A fixed transparent desktop surface. Unreal supplies both motion and the
/// image's crop rectangle; moving a native window never simulates a journey.
@MainActor
final class DesktopAvatarController: ObservableObject {
    static let shared = DesktopAvatarController()
    @Published private(set) var isVisible = !UserDefaults.standard.bool(forKey: "desktopAvatarHidden")
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Drag Muse to choose a resting spot."
    @Published private(set) var isOnJourney = false
    private let renderer = UnrealCharacterRenderer.shared
    private var subscriptions = Set<AnyCancellable>()
    private var surface: AvatarDesktopPanel?
    private var canvas: DesktopAvatarCanvas?
    private var hitPanel: AvatarDesktopPanel?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var viewport = CGRect.zero
    private var pinnedHome = CGPoint.zero
    private var restingAnchor = CGPoint.zero
    private var displayedAnchor = CGPoint.zero
    private var expectedDesktop = false
    private var started = false
    private var dragging = false
    private var dragOrigin = CGPoint.zero
    private var dragMouse = CGPoint.zero
    private var paintedFrame: CharacterFrame?
    private var paintedGlobalRect = CGRect.zero

    func start() {
        guard !started else { return }; started = true
        viewport = Self.desktopBounds()
        let screen = NSScreen.main?.visibleFrame ?? viewport
        let saved = UserDefaults.standard.string(forKey: "desktopAvatarHome").map(NSPointFromString)
        pinnedHome = Self.bounded(saved ?? CGPoint(x: screen.minX + 134, y: screen.minY + 134), screens: NSScreen.screens.map(\.visibleFrame))
        restingAnchor = pinnedHome; displayedAnchor = pinnedHome
        let window = AvatarDesktopPanel(contentRect: viewport)
        window.title = "Muse desktop canvas"
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        let canvas = DesktopAvatarCanvas(frame: CGRect(origin: .zero, size: viewport.size))
        window.contentView = canvas
        self.surface = window; self.canvas = canvas
        let hit = AvatarDesktopPanel(contentRect: .zero)
        hit.title = "Muse desktop avatar"; hit.isExcludedFromWindowsMenu = true
        let drag = AvatarDragHitView(frame: CGRect(x: 0, y: 0, width: 140, height: 148))
        drag.controller = self; hit.contentView = drag; hit.ignoresMouseEvents = false
        self.hitPanel = hit
        renderer.$latestFrame.compactMap { $0 }.sink { [weak self] in self?.receive($0) }.store(in: &subscriptions)
        renderer.$isReady.filter { !$0 }.sink { [weak self] _ in
            // No frame callbacks arrive after a renderer failure. Release a
            // previously interactive pixel immediately instead of leaving a
            // frozen hit window over the user's applications.
            self?.hitPanel?.ignoresMouseEvents = true
            self?.hitPanel?.orderOut(nil)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.screensChanged() }.store(in: &subscriptions)
        if isVisible { window.orderFrontRegardless() }
        if let frame = renderer.latestFrame { receive(frame) }
    }
    func stop() { cancel(); surface?.close(); hitPanel?.close(); subscriptions.removeAll(); started = false }
    func toggleVisibility() {
        start()
        if isVisible {
            cancel(); expectedDesktop = false; restingAnchor = displayedAnchor
            renderer.configureDesktop(nil, state: "idle"); renderer.previewState = "idle"
            isOnJourney = false; isVisible = false
            status = "Avatar hidden. Use Show avatar to bring Muse back."
            surface?.orderOut(nil); hitPanel?.orderOut(nil)
        } else {
            isVisible = true; expectedDesktop = false
            status = "Drag Muse to choose a resting spot."
            renderer.configureDesktop(nil, state: "idle"); renderer.previewState = "idle"
            surface?.orderFrontRegardless()
            if let frame = renderer.latestFrame, !frame.isDesktopScene { receive(frame) }
        }
        UserDefaults.standard.set(!isVisible, forKey: "desktopAvatarHidden")
    }
    /// A local pose can be selected at the avatar's current position without
    /// teleporting it back to its saved home when interrupting a desktop test.
    func prepareForPose() {
        start(); let anchor = currentAnchor(); cancel()
        restingAnchor = anchor; displayedAnchor = anchor; expectedDesktop = false; isOnJourney = false
        renderer.configureDesktop(nil, state: "idle")
        updateHitPanel()
    }
    func jumpToCenter() {
        let screen = actionScreen()
        run(label: "Jumping to the center…") { controller, token in
            try await controller.leap(to: CGPoint(x: screen.midX, y: screen.midY), returning: false, token: token)
            try controller.check(token)
            controller.renderer.animate("stop"); controller.status = "Muse is guarding the center."
        }
    }
    func walkAcrossScreen() {
        let screen = actionScreen()
        run(label: "Walking across the screen…") { controller, token in
            let from = controller.currentAnchor()
            let end = CGPoint(x: from.x < screen.midX ? screen.maxX - 100 : screen.minX + 100,
                              y: min(max(from.y, screen.minY + 105), screen.maxY - 105))
            try await controller.travel(to: end, state: "walk", speed: 180, token: token)
            controller.renderer.animate("idle"); controller.renderer.previewState = "idle"
            controller.status = "Walk complete. Return home or drag Muse to pin a new spot."
        }
    }
    func climbEdge() {
        let screen = actionScreen()
        run(label: "Climbing the screen edge…") { controller, token in
            let from = controller.currentAnchor()
            let edgeX = from.x < screen.midX ? screen.minX + 85 : screen.maxX - 85
            let bottom = CGPoint(x: edgeX, y: screen.minY + 105)
            if from.y > screen.minY + 200 {
                try await controller.leap(to: bottom, returning: false, token: token)
            } else if hypot(from.x - bottom.x, from.y - bottom.y) > 8 {
                try await controller.travel(to: CGPoint(x: edgeX, y: from.y), state: "walk", speed: 150, token: token)
            }
            try await controller.travel(to: CGPoint(x: edgeX, y: screen.maxY - 110), state: "climb", speed: 105, token: token)
            controller.renderer.animate("idle"); controller.renderer.previewState = "idle"
            controller.status = "Climb complete. Return home or drag Muse to pin a new spot."
        }
    }
    func returnHome() {
        run(label: "Returning home…") { controller, token in
            if hypot(controller.currentAnchor().x-controller.pinnedHome.x, controller.currentAnchor().y-controller.pinnedHome.y) > 5 {
                try await controller.leap(to: controller.pinnedHome, returning: true, token: token)
            }
            try controller.check(token)
            controller.restingAnchor = controller.pinnedHome; controller.expectedDesktop = false
            let sequence = controller.renderer.latestFrame?.sequence ?? 0
            controller.renderer.configureDesktop(nil, state: "idle"); controller.renderer.previewState = "idle"
            try await controller.waitForFrame(desktop: false, after: sequence, token: token)
            controller.isOnJourney = false; controller.displayedAnchor = controller.pinnedHome
            controller.status = "Home. Drag Muse to choose a resting spot."
        }
    }
    private func run(label: String, operation: @escaping @MainActor (DesktopAvatarController, Int) async throws -> Void) {
        start(); cancel(); isVisible = true; UserDefaults.standard.set(false, forKey: "desktopAvatarHidden")
        surface?.orderFrontRegardless(); isBusy = true; status = label; updateHitPanel()
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let delay = self.renderer.wakeForInteraction()
                try await self.pause(delay, token: token)
                try await operation(self, token)
                try self.check(token)
                self.isBusy = false; self.updateHitPanel(); self.record("complete")
            } catch {
                guard self.generation == token else { return }
                self.isBusy = false
                self.prepareForPose(); self.renderer.previewState = "idle"
                self.status = error is CancellationError ? "Ready." : "The renderer did not finish the desktop test. Try again."
                self.updateHitPanel()
            }
        }
    }
    private func prepareScene(to destination: CGPoint, token: Int) async throws -> GuardianDesktopScene {
        try check(token)
        let scene = GuardianDesktopScene(viewport: viewport, from: currentAnchor(), to: destination, fromScale: 1, toScale: 1)
        expectedDesktop = true; isOnJourney = true
        let sequence = renderer.latestFrame?.sequence ?? 0
        renderer.configureDesktop(scene, state: "prepare")
        try await waitForFrame(desktop: true, after: sequence, near: scene.from, token: token)
        return scene
    }
    private func leap(to destination: CGPoint, returning: Bool, token: Int) async throws {
        let scene = try await prepareScene(to: destination, token: token)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let direction = GuardianJumpTiming.direction(from: scene.from, to: scene.to)
        for (state, duration) in [("notice", reduced ? 0.08 : GuardianJumpTiming.anticipation),
                                  (returning ? "return" : "jump", reduced ? 0.12 : GuardianJumpTiming.flight),
                                  ("land", reduced ? 0.08 : GuardianJumpTiming.landing)] {
            try check(token); renderer.animate(state, duration: duration, direction: direction)
            record(state); try await pause(duration, token: token)
        }
        displayedAnchor = destination
    }
    private func travel(to destination: CGPoint, state: String, speed: Double, token: Int) async throws {
        let scene = try await prepareScene(to: destination, token: token)
        let distance = hypot(scene.to.x - scene.from.x, scene.to.y - scene.from.y)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : min(16, max(0.6, distance/speed))
        renderer.animate(state, duration: duration, direction: GuardianJumpTiming.direction(from: scene.from, to: scene.to))
        record(state); try await pause(duration, token: token)
        displayedAnchor = destination
    }
    private func waitForFrame(desktop: Bool, after sequence: UInt32, near anchor: CGPoint? = nil, token: Int) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try check(token)
            if let frame = renderer.latestFrame, frame.sequence > sequence, frame.isDesktopScene == desktop {
                if let anchor, let rect = frame.desktopRect {
                    let point = AvatarDesktopGeometry.cropAnchor(rect, viewport: viewport)
                    if hypot(point.x - anchor.x, point.y - anchor.y) < 6 { return }
                } else if anchor == nil { return }
            }
            try await pause(0.016, token: token)
        }
        throw DesktopTestError.frameTimeout
    }
    private func pause(_ seconds: Double, token: Int) async throws {
        try check(token)
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        try check(token)
    }
    private func check(_ token: Int) throws { if Task.isCancelled || generation != token { throw CancellationError() } }
    private func cancel() { generation += 1; task?.cancel(); task = nil; isBusy = false }
    private func currentAnchor() -> CGPoint { displayedAnchor == .zero ? restingAnchor : displayedAnchor }
    private func receive(_ frame: CharacterFrame) {
        guard frame.isDesktopScene == expectedDesktop else { return }
        paintedFrame = frame
        if frame.isDesktopScene, let rect = frame.desktopRect {
            displayedAnchor = AvatarDesktopGeometry.cropAnchor(rect, viewport: viewport)
            paintedGlobalRect = rect.offsetBy(dx: viewport.minX, dy: viewport.minY)
            canvas?.display(frame.image, in: rect)
        } else {
            displayedAnchor = restingAnchor
            let rect = AvatarDesktopGeometry.homeRect(anchor: restingAnchor, viewport: viewport)
            paintedGlobalRect = rect.offsetBy(dx: viewport.minX, dy: viewport.minY)
            canvas?.display(frame.image, in: rect)
        }
        if isVisible, surface?.isVisible != true { surface?.orderFrontRegardless() }; updateHitPanel()
        if frame.sequence % 6 == 0 { record("frame") }
    }
    private func updateHitPanel() {
        guard isVisible, !isBusy, renderer.isReady else { hitPanel?.orderOut(nil); return }
        if dragging { return }
        let overVisiblePixel = paintedFrame.map {
            AvatarDesktopGeometry.hasVisiblePixel(in: $0.image, worldRect: paintedGlobalRect, at: NSEvent.mouseLocation)
        } ?? false
        hitPanel?.ignoresMouseEvents = !overVisiblePixel
        hitPanel?.setFrame(CGRect(x: displayedAnchor.x-70, y: displayedAnchor.y-80, width: 140, height: 148), display: false)
        if hitPanel?.isVisible != true { hitPanel?.orderFrontRegardless() }
    }
    fileprivate func beginDrag() {
        guard isVisible, !isBusy else { return }
        dragOrigin = currentAnchor(); dragMouse = NSEvent.mouseLocation
        prepareForPose(); renderer.previewState = "idle"; dragging = true
    }
    fileprivate func drag() {
        guard dragging else { return }
        let mouse = NSEvent.mouseLocation
        restingAnchor = Self.bounded(CGPoint(x: dragOrigin.x+mouse.x-dragMouse.x, y: dragOrigin.y+mouse.y-dragMouse.y), screens: NSScreen.screens.map(\.visibleFrame))
        displayedAnchor = restingAnchor
        if let frame = renderer.latestFrame, !frame.isDesktopScene { receive(frame) }
        hitPanel?.setFrameOrigin(CGPoint(x: restingAnchor.x-70,y:restingAnchor.y-80))
    }
    fileprivate func endDrag() {
        guard dragging else { return }; dragging = false
        pinnedHome = restingAnchor
        UserDefaults.standard.set(NSStringFromPoint(pinnedHome), forKey: "desktopAvatarHome")
        status = "Pinned where you dragged it."; updateHitPanel(); record("pinned")
    }
    private func screensChanged() {
        prepareForPose(); viewport = Self.desktopBounds(); surface?.setFrame(viewport, display: false)
        canvas?.frame = CGRect(origin: .zero, size: viewport.size)
        pinnedHome = Self.bounded(pinnedHome, screens: NSScreen.screens.map(\.visibleFrame))
        restingAnchor = Self.bounded(restingAnchor, screens: NSScreen.screens.map(\.visibleFrame))
    }
    private func actionScreen() -> CGRect {
        start()
        return NSApp.mainWindow?.screen?.visibleFrame ?? NSScreen.screens.first(where: { $0.visibleFrame.contains(currentAnchor()) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? viewport
    }
    static func desktopBounds() -> CGRect { AvatarDesktopGeometry.viewport(screens:NSScreen.screens.map(\.frame)) }
    static func bounded(_ point: CGPoint, screens: [CGRect]) -> CGPoint { AvatarDesktopGeometry.bounded(point,screens:screens) }
    private func record(_ phase: String) {
        guard ProcessInfo.processInfo.arguments.contains("--visual-test") else { return }
        let data: [String: Any] = ["phase":phase,"x":displayedAnchor.x,"y":displayedAnchor.y,"homeX":pinnedHome.x,"homeY":pinnedHome.y,"desktop":expectedDesktop,"visible":isVisible,"time":Date().timeIntervalSince1970,"pixels":renderer.latestFrame?.image.width ?? 0,"cropWidth":renderer.latestFrame?.desktopRect?.width ?? 220]
        guard var bytes = try? JSONSerialization.data(withJSONObject: data) else { return }; bytes.append(10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muse-desktop-tests-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes); try? handle.close() }
    }
}

private enum DesktopTestError: Error { case frameTimeout }
private final class AvatarDesktopPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque=false; backgroundColor = .clear; hasShadow=false; level = .floating
        isFloatingPanel=true; hidesOnDeactivate=false; isMovableByWindowBackground=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
private final class DesktopAvatarCanvas: NSView {
    private let imageLayer = CALayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer=true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .linear; imageLayer.magnificationFilter = .linear
        imageLayer.actions=["contents":NSNull(),"bounds":NSNull(),"position":NSNull(),"frame":NSNull()]
        layer?.addSublayer(imageLayer)
    }
    func display(_ image: CGImage, in rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame=rect; imageLayer.contents=image
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private final class AvatarDragHitView: NSView {
    weak var controller: DesktopAvatarController?
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        setAccessibilityElement(true);setAccessibilityRole(.button);setAccessibilityLabel("Desktop Muse avatar")
        setAccessibilityHelp("Drag to choose a resting spot. Right-click to hide.")
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.beginDrag() }
    override func mouseDragged(with event: NSEvent) { controller?.drag() }
    override func mouseUp(with event: NSEvent) { controller?.endDrag() }
    override func rightMouseDown(with event: NSEvent) {
        let menu=NSMenu();let hide=NSMenuItem(title:"Hide avatar",action:#selector(hideAvatar),keyEquivalent:"");hide.target=self;menu.addItem(hide)
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func hideAvatar() { controller?.toggleVisibility() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
