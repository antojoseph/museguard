import AppKit

/// A borderless, transparent, always-on-top panel that hosts the pet. It floats
/// above normal windows and joins all Spaces. AvatarDragView owns dragging so
/// speech bubbles, chat fields and transparent space cannot move the window.
final class PetPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        sharingType = ProcessInfo.processInfo.arguments.contains("--visual-test") ? .readOnly : .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // The panel can become key so the in-bubble chat text field accepts input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Transparent render margins may extend beyond the display. Placement
    // clamps the visible body and message independently.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

}
