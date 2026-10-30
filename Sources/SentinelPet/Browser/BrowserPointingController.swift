import AppKit

/// Click-through native geometry. The page cannot style, intercept or hide this
/// indicator; it contains no field text and disappears when its source moves.
@MainActor
final class BrowserPointingController {
    struct NativeWindow: Equatable {
        let id: CGWindowID
        let bounds: CGRect
    }
    private var panel: NSPanel?
    private var timer: Timer?
    private var currentMeasurement: BrowserElementTarget?
    private var currentElement: CGRect?
    private var identity: (document: String, tab: Int, window: Int, nativeWindow: CGWindowID, process: pid_t, bounds: CGRect, deadline: Date)?
    var isVisible: Bool { panel?.isVisible == true }

    static func verifiedWindow(for target: BrowserElementTarget, app: NSRunningApplication) -> CGRect? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return matchingWindow(processID: app.processIdentifier, expectedBounds: target.browserWindow.cgRect, windows: windows)?.bounds
    }
    /// Bind trusted Chrome bounds to exactly one native window. A toolbar or
    /// child popup earlier in z-order cannot replace the source window.
    static func matchingWindow(processID: pid_t, expectedBounds: CGRect, windows: [[String: Any]]) -> NativeWindow? {
        let matches = windows.compactMap { record -> NativeWindow? in
            guard let window = nativeWindow(record, processID: processID),
                  sameBounds(window.bounds, expectedBounds) else { return nil }
            return window
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
    static func sourceWindowIsCurrent(_ expected: NativeWindow, processID: pid_t, foregroundProcessID: pid_t?, windows: [[String: Any]]) -> Bool {
        guard processID == foregroundProcessID,
              let record = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == expected.id }),
              let current = nativeWindow(record, processID: processID) else { return false }
        return current.id == expected.id && sameBounds(current.bounds, expected.bounds)
    }
    private static func nativeWindow(_ record: [String: Any], processID: pid_t) -> NativeWindow? {
        guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
              (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
              let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id != kCGNullWindowID,
              let raw = record[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
              !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return nil }
        return NativeWindow(id: id, bounds: bounds)
    }
    private static func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX-second.minX) <= 8 && abs(first.minY-second.minY) <= 8 &&
        abs(first.width-second.width) <= 8 && abs(first.height-second.height) <= 8
    }
    static func landingPoint(for rect: CGRect) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        // Put Muse beside the control, leaving the marked element unobscured.
        let left = rect.minX - screen.minX, right = screen.maxX - rect.maxX
        let x = right >= left ? rect.maxX + 138 : rect.minX - 138
        return CGPoint(x: min(screen.maxX-115, max(screen.minX+115, x)),
            y: min(screen.maxY-140, max(screen.minY+120, rect.midY-20)))
    }
    func show(target: BrowserElementTarget, resolved: BrowserElementTarget.Resolved, app: NSRunningApplication, bounds: CGRect, landing: CGPoint) {
        hide()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let source = Self.matchingWindow(processID: app.processIdentifier, expectedBounds: bounds, windows: windows) else {
            BrowserTargetDiagnostics.record("marker_source_unavailable"); return
        }
        let rect = resolved.elementRect.insetBy(dx: -5, dy: -5)
        let origin = CGPoint(x: landing.x + (resolved.point.x >= landing.x ? 65 : -65), y: landing.y+23)
        let viewport = rect.union(CGRect(x: origin.x-8, y: origin.y-8, width: 16, height: 16)).insetBy(dx: -14, dy: -14)
        let panel = NSPanel(contentRect: viewport, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.sharingType = .none
        let view = ElementPointerView(frame: CGRect(origin: .zero, size: viewport.size))
        view.element = rect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        view.origin = CGPoint(x: origin.x-viewport.minX, y: origin.y-viewport.minY)
        panel.contentView = view; panel.orderFrontRegardless(); self.panel = panel
        identity = (target.documentID, target.browserWindow.tabID, target.browserWindow.id, source.id, app.processIdentifier, source.bounds, Date(timeIntervalSince1970: target.measuredAt/1000 + 2.5))
        currentMeasurement = target; currentElement = resolved.elementRect
        UnrealCharacterRenderer.shared.setPointingDirection(resolved.point.x < landing.x ? -1 : 1)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validate() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func renew(target: BrowserElementTarget, resolved: BrowserElementTarget.Resolved, app: NSRunningApplication, bounds: CGRect) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let previous = currentMeasurement, let identity, panel?.isVisible == true,
              identity.document == target.documentID, identity.tab == target.browserWindow.tabID,
              identity.window == target.browserWindow.id, identity.process == app.processIdentifier,
              previous.revision == target.revision, previous.rect == target.rect,
              currentElement == resolved.elementRect, Self.sameBounds(bounds, identity.bounds),
              Self.sourceWindowIsCurrent(NativeWindow(id: identity.nativeWindow, bounds: identity.bounds), processID: identity.process,
                foregroundProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier, windows: windows) else { return false }
        self.identity?.deadline = Date(timeIntervalSince1970: target.measuredAt/1000 + 2.5)
        currentMeasurement = target
        return true
    }
    func invalidate(documentID: String?, tabID: Int?, windowID: Int?) {
        guard let identity, identity.document == documentID || (identity.tab == tabID && identity.window == windowID) else { return }
        hide()
    }
    func hide() {
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil; identity = nil; currentMeasurement = nil; currentElement = nil
        UnrealCharacterRenderer.shared.setPointingDirection(nil)
    }
    private func validate() {
        guard let identity else { return }
        // Asking Muse may temporarily make its own chat key, but no pointer is
        // kept across an actual foreground app change or native window move.
        guard Date() < identity.deadline else { BrowserTargetDiagnostics.record("marker_expired"); hide(); return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foreground == identity.process else { BrowserTargetDiagnostics.record("marker_foreground_changed"); hide(); return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard Self.sourceWindowIsCurrent(NativeWindow(id: identity.nativeWindow, bounds: identity.bounds),
            processID: identity.process, foregroundProcessID: foreground, windows: windows) else {
            BrowserTargetDiagnostics.record("marker_window_changed"); hide(); return
        }
    }
}

private final class ElementPointerView: NSView {
    var element = CGRect.zero, origin = CGPoint.zero
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(calibratedRed: 0.93, green: 0.52, blue: 0.18, alpha: 1)
        let frame = NSBezierPath(roundedRect: element, xRadius: 8, yRadius: 8)
        color.withAlphaComponent(0.08).setFill(); frame.fill()
        color.setStroke(); frame.lineWidth = 3; frame.stroke()
        let end = CGPoint(x: min(element.maxX, max(element.minX, origin.x)), y: min(element.maxY, max(element.minY, origin.y)))
        let line = NSBezierPath(); line.move(to: origin); line.line(to: end)
        line.lineWidth = 2; line.setLineDash([4,4], count: 2, phase: 0); line.stroke()
        let angle = atan2(end.y-origin.y, end.x-origin.x), arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: end.x-10*cos(angle-0.45), y: end.y-10*sin(angle-0.45)))
        arrow.line(to: end); arrow.line(to: CGPoint(x: end.x-10*cos(angle+0.45), y: end.y-10*sin(angle+0.45)))
        arrow.lineWidth = 3; arrow.stroke()
    }
}

/// Bounded support metadata only: no page identities, coordinates or values.
@MainActor enum BrowserTargetDiagnostics {
    private static var counts: [String: Int] = [:]
    static func record(_ outcome: String) {
        counts[outcome] = min(1_000_000, (counts[outcome] ?? 0) + 1)
        let record: [String: Any] = ["last_result": outcome, "counts": counts]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let file = BrowserBridgeServer.directory.appendingPathComponent("targeting.json")
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
