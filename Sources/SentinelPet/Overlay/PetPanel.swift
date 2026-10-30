import AppKit

/// A borderless, transparent, always-on-top panel that hosts the pet. It floats
/// above normal windows and joins all Spaces. AvatarDragView owns dragging so
/// speech bubbles, chat fields and transparent space cannot move the window.
final class PetPanel: NSPanel {

    private let acceptsKeyboard: Bool

    init(contentRect: NSRect, acceptsKeyboard: Bool = false) {
        self.acceptsKeyboard = acceptsKeyboard
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
        sharingType = BuildConfiguration.visualTestingEnabled ? .readOnly : .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // Only the chat surface can take keyboard focus. Full-screen transparent
    // renderer panels must leave Chrome's window and current tab focused.
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    // Transparent render margins may extend beyond the display. Placement
    // clamps the visible body and message independently.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

}
