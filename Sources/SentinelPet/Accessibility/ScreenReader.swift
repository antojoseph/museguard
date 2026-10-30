import AppKit
import ApplicationServices
import Foundation

struct ScreenSnapshot {
    let appName: String
    let windowTitle: String?
    let text: String
    let evidence: ContextEvidence
    let source: ScreenSourceIdentity?

    init(appName: String, windowTitle: String?, text: String,
         evidence: ContextEvidence = .unknown, source: ScreenSourceIdentity? = nil) {
        self.appName = appName; self.windowTitle = windowTitle; self.text = text
        self.evidence = evidence; self.source = source
    }
}

enum ScreenReaderError: LocalizedError {
    case accessibilityPermissionRequired
    case noFrontmostApplication
    case ownAppIsFocused
    case noReadableContent(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility access is required before I can read focused-window text."
        case .noFrontmostApplication:
            return "I could not find a focused application to read."
        case .ownAppIsFocused:
            return "Choose another app first, then ask me to read the focused window."
        case let .noReadableContent(appName):
            return "I can access \(appName), but I did not find readable text in the focused window."
        }
    }
}

/// Reads text from the currently focused app/window through the macOS
/// Accessibility API. Analysis uses the authenticated local Muse Glimmer server.
// Traversal state stays inside each read; the only shared objects are immutable
// limits and a serial dispatch queue.
final class ScreenReader: @unchecked Sendable {
    private let maxDepth = 8
    private let maxChildrenPerAttribute = 80
    private let readQueue = DispatchQueue(label: "muse-guard-accessibility", qos: .userInitiated)

    private let textAttributes = [
        kAXSelectedTextAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXPlaceholderValueAttribute,
        kAXDocumentAttribute
    ]

    private let childAttributes = [
        kAXVisibleChildrenAttribute,
        kAXChildrenAttribute,
        kAXRowsAttribute,
        kAXColumnsAttribute
    ]

    func readFocusedContext(maxCharacters: Int = 8_000) throws -> ScreenSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ScreenReaderError.noFrontmostApplication
        }
        return try readContext(for:app,maxCharacters:maxCharacters)
    }

    /// AX messaging can wait on another application. Keep it off the UI actor,
    /// bound each message and the whole traversal, and release cancelled reads
    /// without waiting for a slow application to finish its current callback.
    func readContextAsync(for app: NSRunningApplication, maxCharacters: Int = 8_000) async throws -> ScreenSnapshot {
        let request = AccessibilityReadRequest()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                readQueue.async { [self] in
                    guard !request.isCancelled else { return }
                    do {
                        let snapshot = try readContext(for: app, maxCharacters: maxCharacters,
                            cancelled: { request.isCancelled })
                        request.finish(.success(snapshot))
                    } catch { request.finish(.failure(error)) }
                }
            }
        }, onCancel: { request.cancel() })
    }

    /// A missing or ambiguous window number is never replaced by an entire
    /// desktop capture. The caller may still use AX text with this identity.
    func sourceIdentity(for app: NSRunningApplication) -> ScreenSourceIdentity? {
        guard !app.isTerminated else { return nil }
        let budget = AccessibilityReadBudget(duration: 0.2)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = AccessibilityPermissionController.isTrusted ?
            focusedWindow(for: appElement, budget: budget) : nil
        return sourceIdentity(for: app, focusedWindow: focusedWindow, budget: budget)
    }

    /// The last external app remains the source while Muse's chat owns focus.
    func readContext(for app: NSRunningApplication, maxCharacters: Int = 8_000) throws -> ScreenSnapshot {
        try readContext(for: app, maxCharacters: maxCharacters, cancelled: { false })
    }

    private func readContext(for app: NSRunningApplication, maxCharacters: Int,
        cancelled: @escaping () -> Bool) throws -> ScreenSnapshot {
        guard AccessibilityPermissionController.isTrusted else {
            throw ScreenReaderError.accessibilityPermissionRequired
        }

        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ScreenReaderError.ownAppIsFocused
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "focused app"
        let budget = AccessibilityReadBudget(duration: 0.7, cancelled: cancelled)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = focusedWindow(for: appElement, budget: budget)
        let source = sourceIdentity(for: app, focusedWindow: focusedWindow, budget: budget)
        let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute, from: appElement, budget: budget)
        let roots = [focusedElement, focusedWindow].compactMap { $0 }

        var visited = Set<CFHashCode>()
        var collector = AccessibilityEvidenceBuilder(maxCharacters: min(32_000, max(0, maxCharacters)))
        for root in roots where !collector.isFull {
            collectText(from: root, depth: 0, inControlRegion: false,
                visited: &visited, collector: &collector, budget: budget)
        }
        if cancelled() { throw CancellationError() }
        if budget.exhausted || collector.isFull { collector.markTruncated() }

        let text = collector.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ScreenReaderError.noReadableContent(appName)
        }

        return ScreenSnapshot(
            appName: appName,
            windowTitle: source.windowTitle,
            text: text, evidence: collector.evidence, source: source
        )
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        inControlRegion: Bool,
        visited: inout Set<CFHashCode>,
        collector: inout AccessibilityEvidenceBuilder,
        budget: AccessibilityReadBudget
    ) {
        guard depth <= maxDepth, !collector.isFull, !budget.exhausted else { return }

        let elementID = CFHash(element)
        guard visited.insert(elementID).inserted else { return }
        guard budget.visitNode() else { return }
        let subrole = copyStringAttribute(kAXSubroleAttribute, from: element, budget: budget)
        guard subrole != "AXSecureTextField" else { return }
        guard (copyAttribute(kAXHiddenAttribute, from: element, budget: budget) as? Bool) != true else { return }
        let role = copyStringAttribute(kAXRoleAttribute, from: element, budget: budget) ?? ""
        let controls = inControlRegion || AccessibilityEvidenceBuilder.isControlRegion(role)
        let description = copyStringAttribute(kAXDescriptionAttribute, from: element, budget: budget)
        let substantialVisual = !controls && isSubstantialVisual(role: role, description: description,
            element: element, budget: budget)
        collector.visit(role: role, inControlRegion: controls, substantialVisual: substantialVisual)

        for attribute in textAttributes where !collector.isFull {
            collector.append(attribute == kAXDescriptionAttribute ? description :
                copyStringAttribute(attribute, from: element, budget: budget),
                role: role, inControlRegion: controls)
        }

        guard depth < maxDepth else { return }

        for child in childElements(of: element, budget: budget) where !collector.isFull && !budget.exhausted {
            collectText(
                from: child, depth: depth + 1, inControlRegion: controls,
                visited: &visited,
                collector: &collector, budget: budget
            )
        }
    }

    private func childElements(of element: AXUIElement, budget: AccessibilityReadBudget) -> [AXUIElement] {
        var children: [AXUIElement] = []

        for attribute in childAttributes {
            guard !budget.exhausted else { break }
            AXUIElementSetMessagingTimeout(element, Float(min(0.08, max(0.001, budget.remaining))))
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0,
                maxChildrenPerAttribute, &values) == .success,
                let array = values as? [Any] else { continue }
            children.append(contentsOf: array.compactMap(axElement))
            // Prefer the application's visible subtree. Only fall back to the
            // broader child/row/column attributes when it exposes no such list.
            if attribute == kAXVisibleChildrenAttribute, !children.isEmpty { break }
        }

        return children
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement?, budget: AccessibilityReadBudget) -> String? {
        guard let element else { return nil }
        return stringValue(from: copyAttribute(attribute, from: element, budget: budget))
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement, budget: AccessibilityReadBudget) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element, budget: budget) else { return nil }
        return axElement(from: value)
    }

    private func focusedWindow(for appElement: AXUIElement, budget: AccessibilityReadBudget) -> AXUIElement? {
        copyElementAttribute(kAXFocusedWindowAttribute, from: appElement, budget: budget) ??
            copyElementAttribute(kAXMainWindowAttribute, from: appElement, budget: budget)
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement, budget: AccessibilityReadBudget) -> Any? {
        guard !budget.exhausted else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.08, max(0.001, budget.remaining))))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func sourceIdentity(for app: NSRunningApplication, focusedWindow: AXUIElement?,
        budget: AccessibilityReadBudget) -> ScreenSourceIdentity {
        let attributes = windowAttributes(for: focusedWindow, budget: budget)
        let title = attributes.title
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter {
                ScreenSourceIdentity.metadataInteger($0[kCGWindowOwnerPID as String]) == Int64(app.processIdentifier) &&
                    ScreenSourceIdentity.metadataInteger($0[kCGWindowLayer as String]) == 0
            }
        let candidates = windows.compactMap { window -> ScreenWindowCandidate? in
            guard let rawID = ScreenSourceIdentity.metadataInteger(window[kCGWindowNumber as String]),
                  rawID > 0, rawID <= Int64(UInt32.max) else { return nil }
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap {
                CGRect(dictionaryRepresentation: $0 as CFDictionary)
            }
            return ScreenWindowCandidate(id: UInt32(rawID), title: window[kCGWindowName as String] as? String, bounds: bounds)
        }
        let windowID = ScreenSourceIdentity.captureWindowID(focusedTitle: title, focusedBounds: attributes.bounds, candidates: candidates)
        let window = windowID.flatMap { id in candidates.first { $0.id == id } }
        return ScreenSourceIdentity(processID: app.processIdentifier, bundleID: app.bundleIdentifier,
            windowID: windowID,
            windowTitle: title ?? window?.title,
            appName: app.localizedName ?? app.bundleIdentifier ?? "Current app")
    }

    private func windowAttributes(for element: AXUIElement?, budget: AccessibilityReadBudget) -> (title: String?, bounds: CGRect?) {
        guard let element, !budget.exhausted else { return (nil, nil) }
        AXUIElementSetMessagingTimeout(element, Float(min(0.08, max(0.001, budget.remaining))))
        var result: CFArray?
        let names = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &result) == .success,
              let values = result as? [Any], values.count == 3 else { return (nil, nil) }
        let title = stringValue(from: values[0])
        guard CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID() else { return (title, nil) }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[1] as! AXValue, .cgPoint, &position),
              AXValueGetValue(values[2] as! AXValue, .cgSize, &size) else { return (title, nil) }
        let bounds = CGRect(origin: position, size: size)
        return (title, ScreenSourceIdentity.validWindowBounds(bounds) ? bounds : nil)
    }

    private func isSubstantialVisual(role: String, description: String?, element: AXUIElement,
        budget: AccessibilityReadBudget) -> Bool {
        let hint = (description ?? "").lowercased()
        let image = ["AXImage", "AXVideo", "AXCanvas"].contains(role)
        let canvas = ["AXGroup", "AXUnknown", "AXScrollArea"].contains(role) &&
            ["canvas", "diagram", "drawing", "chart", "video"].contains { hint.contains($0) }
        guard image || canvas, let value = copyAttribute(kAXSizeAttribute, from: element, budget: budget),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return false }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return false }
        return size.width >= 96 && size.height >= 64
    }

    private func axElement(from value: Any) -> AXUIElement? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringValue(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let attributedString as NSAttributedString:
            return attributedString.string
        case let strings as [String]:
            return strings.joined(separator: " ")
        case let url as URL:
            return url.absoluteString
        default:
            return nil
        }
    }
}

private final class AccessibilityReadBudget {
    private let deadline: TimeInterval
    private let cancelled: () -> Bool
    private var nodes = 0
    init(duration: TimeInterval, cancelled: @escaping () -> Bool = { false }) {
        deadline = ProcessInfo.processInfo.systemUptime + duration; self.cancelled = cancelled
    }
    var remaining: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }
    var exhausted: Bool { remaining <= 0 || cancelled() || nodes >= 384 }
    func visitNode() -> Bool {
        guard !exhausted else { return false }
        nodes += 1; return true
    }
}

private final class AccessibilityReadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScreenSnapshot, Error>?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ continuation: CheckedContinuation<ScreenSnapshot, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func finish(_ result: Result<ScreenSnapshot, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
