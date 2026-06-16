import AppKit
import SwiftUI

/// Creates and manages the floating pet panel and its SwiftUI content.
@MainActor
final class PetOverlayController {
    private var panel: PetPanel?
    private let viewModel: PetViewModel
    private var moveObserver: NSObjectProtocol?

    /// Total content size: enough vertical room for a speech bubble above the
    /// pet, which sits anchored at the bottom-trailing corner.
    private let contentSize = NSSize(width: 360, height: 420)

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        let hosting = PetHostingView(
            rootView: PetRootView(viewModel: viewModel),
            viewModel: viewModel
        )
        hosting.frame = NSRect(origin: .zero, size: contentSize)

        let panel = PetPanel(contentRect: NSRect(origin: .zero, size: contentSize))
        panel.contentView = hosting
        panel.positionAtSavedOrDefault()
        panel.orderFrontRegardless()

        // Remember where the user drags the pet to.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { panel.saveOrigin() }
        }

        self.panel = panel
        viewModel.greet()
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }
}

/// Keeps transparent regions of the overlay from intercepting clicks meant for
/// underlying apps while preserving drag behavior on the visible pet and bubble.
@MainActor
private final class PetHostingView: NSHostingView<PetRootView> {
    private let viewModel: PetViewModel

    private let petHitRect = NSRect(x: 252, y: 8, width: 100, height: 104)

    init(rootView: PetRootView, viewModel: PetViewModel) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: PetRootView) {
        fatalError("Use init(rootView:viewModel:) instead.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard activeHitRects.contains(where: { $0.contains(point) }) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }

    private var activeHitRects: [NSRect] {
        if viewModel.isChatOpen {
            return [petHitRect, bubbleHitRect(for: .alert)]
        }

        guard let bubbleText = viewModel.bubbleText else {
            return [petHitRect]
        }
        return [petHitRect, bubbleHitRect(for: viewModel.bubbleMood, text: bubbleText)]
    }

    private func bubbleHitRect(for mood: PetMood) -> NSRect {
        bubbleHitRect(for: mood, text: nil)
    }

    private func bubbleHitRect(for mood: PetMood, text: String?) -> NSRect {
        let width = bubbleWidth(for: mood, text: text)
        let height = bubbleHeight(for: mood, width: width, text: text)
        return NSRect(x: 352 - width, y: 116, width: width, height: height)
    }

    private func bubbleWidth(for mood: PetMood, text: String?) -> CGFloat {
        let maxWidth: CGFloat
        let minWidth: CGFloat

        switch mood {
        case .idle:
            maxWidth = 220
            minWidth = 150
        case .scanning:
            maxWidth = 292
            minWidth = 180
        case .alert:
            maxWidth = 336
            minWidth = 210
        }

        guard let text else { return maxWidth }

        let longestLine = text
            .components(separatedBy: .newlines)
            .map(\.count)
            .max() ?? 0
        let estimatedWidth = CGFloat(longestLine) * 7.2 + 46
        return min(max(estimatedWidth, minWidth), maxWidth)
    }

    private func bubbleHeight(for mood: PetMood, width: CGFloat, text: String?) -> CGFloat {
        let maxHeight: CGFloat
        let minHeight: CGFloat
        let verticalPadding: CGFloat

        switch mood {
        case .idle:
            maxHeight = 96
            minHeight = 42
            verticalPadding = 16
        case .scanning:
            maxHeight = 184
            minHeight = 48
            verticalPadding = 20
        case .alert:
            maxHeight = 296
            minHeight = 54
            verticalPadding = 22
        }

        guard let text else { return maxHeight }

        let charactersPerLine = max(18, Int((width - 44) / 7.2))
        let estimatedLines = text
            .components(separatedBy: .newlines)
            .map { max(1, Int(ceil(Double($0.count) / Double(charactersPerLine)))) }
            .reduce(0, +)
        let estimatedHeight = CGFloat(estimatedLines) * 18 + verticalPadding
        return min(max(estimatedHeight, minHeight), maxHeight)
    }
}
