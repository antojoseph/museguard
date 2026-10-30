#if MUSE_SECRET_PASTE_FIXTURE
import AppKit

/// Disposable local test window. It never saves or sends pasted values.
@main struct SecretPasteFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = NSMenu()
        root.submenu?.addItem(withTitle: "Quit Paste Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(root)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        appMenu.addItem(edit); NSApplication.shared.mainMenu = appMenu
        let window = NSWindow(contentRect: NSRect(x: 150, y: 180, width: 600, height: 400), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Muse Secret Paste Test"
        let content = NSView(frame: window.contentView!.bounds)
        let heading = NSTextField(labelWithString: "Harmless native paste test")
        heading.font = .boldSystemFont(ofSize: 22); heading.frame = NSRect(x: 24,y: 335,width: 550,height: 32)
        let note = NSTextField(wrappingLabelWithString: "Use only the public BIP39 test phrase. This window never saves or transmits text. Muse should warn after a native keyboard paste; it cannot block it.")
        note.frame = NSRect(x: 24,y: 263,width: 550,height: 62)
        let scroll = NSScrollView(frame: NSRect(x: 24,y: 30,width: 550,height: 220)); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds); editor.isRichText = false; editor.font = .systemFont(ofSize: 17); editor.setAccessibilityLabel("Public test phrase")
        scroll.documentView = editor
        content.addSubview(heading); content.addSubview(note); content.addSubview(scroll)
        window.contentView = content; self.window = window; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
