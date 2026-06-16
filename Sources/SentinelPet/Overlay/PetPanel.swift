import AppKit

/// A borderless, transparent, always-on-top panel that hosts the pet. It floats
/// above normal windows, joins all Spaces, and is draggable by its background so
/// the user can reposition the pet anywhere on screen.
final class PetPanel: NSPanel {
    private static let originDefaultsKey = "petFrameOrigin"

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
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // Never steal focus / app activation when the user drags or clicks the pet.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Place the pet at its last saved location, or default to the bottom-right
    /// corner of the main screen's visible area.
    func positionAtSavedOrDefault() {
        if let saved = UserDefaults.standard.string(forKey: Self.originDefaultsKey),
           !saved.isEmpty {
            setFrameOrigin(NSPointFromString(saved))
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - frame.width - 16,
                y: visible.minY + 16
            )
            setFrameOrigin(origin)
        }
    }

    /// Persist the current location so the pet returns to where the user left it.
    func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originDefaultsKey)
    }
}
