import AppKit

/// A deliberately local, non-sensitive app for testing real Accessibility and
/// focused-window image capture. Chart facts exist only in the image pixels.
@MainActor
private final class ContextFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let page = NSView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let controls = NSStackView(views: [
            NSButton(title: "Text page", target: self, action: #selector(showTextPage)),
            NSButton(title: "Visual page", target: self, action: #selector(showVisualPage))
        ])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        content.addSubview(page)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            page.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 24),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Muse Context Test"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        showTextPage()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showTextPage() {
        let text = NSTextField(wrappingLabelWithString: """
        Harbor customer guide

        Harbor support is available from 09:30 to 17:30 on weekdays.

        The access code for the local demonstration is CEDAR-42.

        Standard orders arrive in three business days. Returns are accepted within thirty days. This guide asks for no passwords, payment, or downloads.
        """)
        text.font = .systemFont(ofSize: 22)
        text.textColor = .labelColor
        text.setAccessibilityRole(.staticText)
        text.setAccessibilityElement(true)
        display(text)
    }

    @objc private func showVisualPage() {
        let image = NSImage(size: NSSize(width: 700, height: 390), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            Self.draw("Tickets processed", at: NSPoint(x: 30, y: 338), size: 27, weight: .semibold)
            let days = ["Monday", "Tuesday", "Wednesday"]
            let values = [12, 36, 24]
            let colors = [NSColor.systemBlue, NSColor.systemOrange, NSColor.systemTeal]
            for index in days.indices {
                let x = CGFloat(95 + index * 205)
                let height = CGFloat(values[index]) * 6
                colors[index].setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 80, width: 110, height: height),
                    xRadius: 8, yRadius: 8).fill()
                Self.draw(String(values[index]), at: NSPoint(x: x + 37, y: 89 + height), size: 26, weight: .semibold)
                Self.draw(days[index], at: NSPoint(x: x - 10, y: 38), size: 21, weight: .regular)
            }
            return true
        }
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel("Activity chart")
        display(imageView)
    }

    private func display(_ view: NSView) {
        page.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            view.topAnchor.constraint(equalTo: page.topAnchor),
            view.bottomAnchor.constraint(equalTo: page.bottomAnchor)
        ])
    }

    private static func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.black
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private enum ContextFixtureApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ContextFixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
