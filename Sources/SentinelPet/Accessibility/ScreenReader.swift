import AppKit
import ApplicationServices
import Foundation

struct ScreenSnapshot {
    let appName: String
    let windowTitle: String?
    let text: String
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
final class ScreenReader {
    private let maxDepth = 8
    private let maxChildrenPerAttribute = 120

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
        guard AccessibilityPermissionController.isTrusted else {
            throw ScreenReaderError.accessibilityPermissionRequired
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ScreenReaderError.noFrontmostApplication
        }

        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ScreenReaderError.ownAppIsFocused
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "focused app"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute, from: appElement)
        let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let roots = [focusedElement, focusedWindow, appElement].compactMap { $0 }

        var visited = Set<CFHashCode>()
        var collector = TextCollector(maxCharacters: maxCharacters)
        for root in roots where !collector.isFull {
            collectText(from: root, depth: 0, visited: &visited, collector: &collector)
        }

        let text = collector.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ScreenReaderError.noReadableContent(appName)
        }

        return ScreenSnapshot(
            appName: appName,
            windowTitle: copyStringAttribute(kAXTitleAttribute, from: focusedWindow),
            text: text
        )
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        visited: inout Set<CFHashCode>,
        collector: inout TextCollector
    ) {
        guard depth <= maxDepth, !collector.isFull else { return }

        let elementID = CFHash(element)
        guard visited.insert(elementID).inserted else { return }

        for attribute in textAttributes where !collector.isFull {
            collector.append(copyStringAttribute(attribute, from: element))
        }

        guard depth < maxDepth else { return }

        for child in childElements(of: element) where !collector.isFull {
            collectText(
                from: child,
                depth: depth + 1,
                visited: &visited,
                collector: &collector
            )
        }
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var children: [AXUIElement] = []

        for attribute in childAttributes {
            guard let value = copyAttribute(attribute, from: element) else {
                continue
            }

            if let child = axElement(from: value) {
                children.append(child)
            } else if let childArray = value as? [Any] {
                children.append(
                    contentsOf: childArray.compactMap(axElement).prefix(maxChildrenPerAttribute)
                )
            }
        }

        return children
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement?) -> String? {
        guard let element else { return nil }
        return stringValue(from: copyAttribute(attribute, from: element))
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else { return nil }
        return axElement(from: value)
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
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

private struct TextCollector {
    let maxCharacters: Int

    private var pieces: [String] = []
    private var seenPieces = Set<String>()
    private var characterCount = 0

    init(maxCharacters: Int) {
        self.maxCharacters = maxCharacters
    }

    var isFull: Bool {
        characterCount >= maxCharacters
    }

    var text: String {
        pieces.joined(separator: "\n")
    }

    mutating func append(_ text: String?) {
        guard !isFull, let text else { return }

        let normalized = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty, seenPieces.insert(normalized).inserted else {
            return
        }

        let remaining = maxCharacters - characterCount
        let clipped = String(normalized.prefix(remaining))
        pieces.append(clipped)
        characterCount += clipped.count
    }
}
