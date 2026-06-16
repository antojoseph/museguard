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
            let origin = clampedOrigin(for: NSPointFromString(saved))
            setFrameOrigin(origin)
            saveOrigin()
            return
        }
        let origin = defaultOrigin()
        setFrameOrigin(origin)
    }

    /// Persist the current location so the pet returns to where the user left it.
    func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originDefaultsKey)
    }

    private func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return clampedOrigin(
            for: NSPoint(
                x: visible.maxX - frame.width - 16,
                y: visible.minY + 16
            ),
            in: visible
        )
    }

    private func clampedOrigin(for origin: NSPoint) -> NSPoint {
        let proposedFrame = NSRect(origin: origin, size: frame.size)
        let targetScreen = screenIntersecting(proposedFrame)
            ?? nearestScreen(to: proposedFrame)
            ?? NSScreen.main

        guard let visible = targetScreen?.visibleFrame else {
            return origin
        }
        return clampedOrigin(for: origin, in: visible)
    }

    private func clampedOrigin(for origin: NSPoint, in visibleFrame: NSRect) -> NSPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)

        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    private func screenIntersecting(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(rect) }
    }

    private func nearestScreen(to rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.min { lhs, rhs in
            lhs.visibleFrame.center.distanceSquared(to: center)
                < rhs.visibleFrame.center.distanceSquared(to: center)
        }
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private extension NSPoint {
    func distanceSquared(to other: NSPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
