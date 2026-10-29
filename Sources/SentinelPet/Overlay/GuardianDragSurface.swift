import AppKit
import SwiftUI

struct GuardianDragActions {
    var begin: () -> Bool
    var move: (CGSize) -> Void
    var end: () -> Void
}

/// Explicit mouse handling separates a click from a drag and leaves speech
/// fields/buttons alone. The window's alpha hit test excludes empty pixels.
struct GuardianDragSurface: NSViewRepresentable {
    let actions: GuardianDragActions
    func makeNSView(context: Context) -> AvatarDragView { AvatarDragView(actions: actions) }
    func updateNSView(_ view: AvatarDragView, context: Context) { view.actions = actions }
}

final class AvatarDragView: NSView {
    var actions: GuardianDragActions
    private var pressedAt: CGPoint?
    private var dragging = false
    init(actions: GuardianDragActions) {
        self.actions = actions
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Muse avatar")
        setAccessibilityHelp("Drag to choose a resting spot. Click to chat. Right-click to hide.")
        toolTip = "Drag to move · Click to chat · Right-click to hide"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseDown(with event: NSEvent) { pressedAt = screenPoint(event); dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt else { return }
        let p = screenPoint(event)
        let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
        if !dragging {
            guard hypot(delta.width, delta.height) >= 4, actions.begin() else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        actions.move(delta)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressedAt != nil else { return }
        pressedAt = nil
        if dragging { actions.end(); NSCursor.pop() }
        else { SentinelPetRuntime.shared.openPetChat() }
        dragging = false
    }
    override func accessibilityPerformPress() -> Bool { SentinelPetRuntime.shared.openPetChat(); return true }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide Muse", action: #selector(hideAvatar), keyEquivalent: "")
        hide.target = self; menu.addItem(hide)
        let automatic = NSMenuItem(title:"Stay out of my way",action:#selector(toggleAutomatic),keyEquivalent:"")
        automatic.target = self
        automatic.state = SentinelPetRuntime.shared.petViewModel.automaticallyPositions ? .on : .off
        menu.addItem(automatic)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func toggleAutomatic() { SentinelPetRuntime.shared.petViewModel.automaticallyPositions.toggle() }
    @objc private func hideAvatar() { SentinelPetRuntime.shared.toggleAvatarVisibility() }
}
