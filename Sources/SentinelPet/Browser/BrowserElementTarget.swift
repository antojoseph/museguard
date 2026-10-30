import AppKit
import ApplicationServices
import Foundation

/// UI geometry only. Page contents and field values never enter this value.
/// CSS pixels are converted with Chrome's page zoom, never Retina DPR.
struct BrowserElementTarget: Codable, Equatable, Sendable {
    struct Rect: Codable, Equatable, Sendable {
        let x: Double, y: Double, width: Double, height: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    struct Viewport: Codable, Equatable, Sendable {
        let width: Double, height: Double, scrollX: Double, scrollY: Double
        let devicePixelRatio: Double, visualScale: Double, offsetX: Double, offsetY: Double
        enum CodingKeys: String, CodingKey {
            case width, height, scrollX = "scroll_x", scrollY = "scroll_y", devicePixelRatio = "device_pixel_ratio"
            case visualScale = "visual_scale", offsetX = "offset_x", offsetY = "offset_y"
        }
    }
    struct BrowserWindow: Codable, Equatable, Sendable {
        let id: Int, tabID: Int
        let left: Double, top: Double, width: Double, height: Double, zoom: Double
        enum CodingKeys: String, CodingKey { case id, tabID = "tab_id", left, top, width, height, zoom }
        var cgRect: CGRect { CGRect(x: left, y: top, width: width, height: height) }
    }
    struct Pointer: Codable, Equatable, Sendable {
        let clientX: Double, clientY: Double, screenX: Double, screenY: Double, capturedAt: Double
        enum CodingKeys: String, CodingKey {
            case clientX = "client_x", clientY = "client_y", screenX = "screen_x", screenY = "screen_y", capturedAt = "captured_at"
        }
    }
    struct Context {
        let documentID: String, revision: Int, tabID: Int, browserWindowID: Int
        /// Core Graphics global points: upper-left origin on the primary display.
        let windowBounds: CGRect
        let primaryScreenTop: CGFloat
        let nowMS: Double
        let processID: pid_t?
        /// AppKit screen rectangles; optional in deterministic geometry tests.
        let screens: [CGRect]
        init(documentID: String, revision: Int, tabID: Int, browserWindowID: Int,
             windowBounds: CGRect, primaryScreenTop: CGFloat, nowMS: Double = Date().timeIntervalSince1970 * 1000,
             processID: pid_t? = nil, screens: [CGRect] = []) {
            self.documentID = documentID; self.revision = revision; self.tabID = tabID; self.browserWindowID = browserWindowID
            self.windowBounds = windowBounds; self.primaryScreenTop = primaryScreenTop; self.nowMS = nowMS
            self.processID = processID; self.screens = screens
        }
    }
    struct Resolved: Equatable {
        enum Basis: String { case accessibility, trustedPointer = "trusted_pointer" }
        let elementRect: CGRect
        let point: CGPoint
        let basis: Basis
    }
    let version: Int, documentID: String, revision: Int
    let measuredAt: Double, rect: Rect, viewport: Viewport, browserWindow: BrowserWindow
    let pointer: Pointer?
    enum CodingKeys: String, CodingKey {
        case version, documentID = "document_id", revision, measuredAt = "measured_at", rect, viewport
        case browserWindow = "browser_window", pointer
    }

    func resolve(context: Context, trustedViewportBounds suppliedViewport: CGRect? = nil) -> Resolved? {
        guard validated(context: context) else { return nil }
        let zoom = browserWindow.zoom
        let expectedSize = CGSize(width: viewport.width * zoom, height: viewport.height * zoom)
        let accessibility = suppliedViewport ?? context.processID.flatMap {
            Self.accessibilityViewportBounds(processID: $0, windowBounds: context.windowBounds,
                viewportSize: expectedSize)
        }
        let frame: CGRect, basis: Resolved.Basis
        if let accessibility, Self.validRect(accessibility),
           abs(accessibility.width - expectedSize.width) <= 24,
           abs(accessibility.height - expectedSize.height) <= 24,
           Self.contains(context.windowBounds, accessibility, tolerance: 2) {
            frame = accessibility; basis = .accessibility
        } else if let pointer, pointer.capturedAt.isFinite,
                  pointer.capturedAt >= context.nowMS - 12000, pointer.capturedAt <= context.nowMS + 250,
                  Self.between(pointer.clientX, 0, viewport.width), Self.between(pointer.clientY, 0, viewport.height),
                  Self.between(pointer.screenX, -100000, 100000), Self.between(pointer.screenY, -100000, 100000),
                  context.windowBounds.insetBy(dx: -2, dy: -2).contains(CGPoint(x: pointer.screenX, y: pointer.screenY)) {
            // This anchor is recorded only from isTrusted pointer/mouse input
            // in the isolated content script and checked against native bounds.
            let calibrated = CGRect(x: pointer.screenX - pointer.clientX * zoom,
                y: pointer.screenY - pointer.clientY * zoom, width: expectedSize.width, height: expectedSize.height)
            guard Self.contains(context.windowBounds, calibrated, tolerance: 2) else { return nil }
            frame = calibrated; basis = .trustedPointer
        } else { return nil }
        let cgElement = CGRect(x: frame.minX + rect.x * zoom, y: frame.minY + rect.y * zoom,
            width: rect.width * zoom, height: rect.height * zoom).intersection(frame).intersection(context.windowBounds)
        guard Self.validRect(cgElement) else { return nil }
        var element = CGRect(x: cgElement.minX, y: context.primaryScreenTop - cgElement.maxY,
            width: cgElement.width, height: cgElement.height)
        if !context.screens.isEmpty {
            guard let visible = context.screens.map({ element.intersection($0) }).filter(Self.validRect)
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            element = visible
        }
        return Resolved(elementRect: element, point: CGPoint(x: element.midX, y: element.midY), basis: basis)
    }

    func validated(context: Context) -> Bool {
        version == 1 && documentID == context.documentID && !documentID.isEmpty && documentID.utf8.count <= 256 &&
        revision >= 0 && revision == context.revision && browserWindow.id > 0 && browserWindow.id == context.browserWindowID &&
        browserWindow.tabID > 0 && browserWindow.tabID == context.tabID &&
        measuredAt.isFinite && context.nowMS.isFinite && measuredAt >= context.nowMS - 2500 && measuredAt <= context.nowMS + 250 &&
        Self.between(browserWindow.zoom, 0.25, 5) && Self.between(viewport.width, 1, 100000) &&
        Self.between(viewport.height, 1, 100000) && Self.between(viewport.devicePixelRatio, 0.1, 32) &&
        Self.between(viewport.scrollX, -10000000, 10000000) && Self.between(viewport.scrollY, -10000000, 10000000) &&
        viewport.visualScale.isFinite && abs(viewport.visualScale - 1) < 0.001 &&
        viewport.offsetX.isFinite && abs(viewport.offsetX) < 0.001 && viewport.offsetY.isFinite && abs(viewport.offsetY) < 0.001 &&
        context.primaryScreenTop.isFinite && Self.validRect(context.windowBounds) && Self.validRect(browserWindow.cgRect) &&
        Self.sameRect(context.windowBounds, browserWindow.cgRect, tolerance: 8) &&
        Self.between(rect.x, 0, viewport.width) && Self.between(rect.y, 0, viewport.height) &&
        Self.between(rect.width, 1, viewport.width) && Self.between(rect.height, 1, viewport.height) &&
        rect.x + rect.width <= viewport.width + 0.01 && rect.y + rect.height <= viewport.height + 0.01
    }

    private static func between(_ value: Double, _ low: Double, _ high: Double) -> Bool {
        value.isFinite && value >= low && value <= high
    }
    private static func validRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
    private static func sameRect(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    private static func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat) -> Bool {
        outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
    }

    /// Read only window/viewport geometry with a strict AX time/node budget.
    /// A web area reporting full document bounds fails the size match rather
    /// than becoming an invented titlebar offset. No AX text is collected.
    static func accessibilityViewportBounds(processID: pid_t, windowBounds: CGRect, viewportSize: CGSize) -> CGRect? {
        guard AXIsProcessTrusted(), processID > 0, validRect(windowBounds) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        func attributes(_ element: AXUIElement, _ names: [String]) -> [Any]? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.015)
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success else { return nil }
            return result as? [Any]
        }
        func frame(_ values: [Any], position: Int, size: Int) -> CGRect? {
            guard values.count > max(position, size), CFGetTypeID(values[position] as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(values[size] as CFTypeRef) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(values[position] as! AXValue, .cgPoint, &p),
                  AXValueGetValue(values[size] as! AXValue, .cgSize, &s) else { return nil }
            let result = CGRect(origin: p, size: s)
            return validRect(result) ? result : nil
        }
        let app = AXUIElementCreateApplication(processID)
        guard let focused = attributes(app, [kAXFocusedWindowAttribute, kAXMainWindowAttribute]) else { return nil }
        let windows = focused.compactMap { value -> AXUIElement? in
            CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
        guard let window = windows.first(where: { element in
            guard let values = attributes(element, [kAXPositionAttribute, kAXSizeAttribute]),
                  let rect = frame(values, position: 0, size: 1) else { return false }
            return sameRect(rect, windowBounds, tolerance: 4)
        }) else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)], visited = Set<CFHashCode>(), matches: [CGRect] = []
        while !queue.isEmpty, visited.count < 100, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue.removeFirst()
            guard visited.insert(CFHash(element)).inserted,
                  let values = attributes(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]), values.count == 4 else { continue }
            let role = values[0] as? String
            if let role, ["AXWebArea", "AXScrollArea"].contains(role), let rect = frame(values, position: 1, size: 2),
               abs(rect.width - viewportSize.width) <= 24, abs(rect.height - viewportSize.height) <= 24,
               contains(windowBounds, rect, tolerance: 2) { matches.append(rect) }
            if depth < 7, let children = values[3] as? [Any] {
                for value in children.prefix(64) where CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
                    queue.append((value as! AXUIElement, depth + 1))
                }
            }
        }
        guard let first = matches.first, matches.allSatisfy({ sameRect(first, $0, tolerance: 2) }) else { return nil }
        return first
    }
}
