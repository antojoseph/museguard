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
        guard viewModel.bubbleText != nil else {
            return [petHitRect]
        }
        return [petHitRect, bubbleHitRect(for: viewModel.bubbleMood)]
    }

    private func bubbleHitRect(for mood: PetMood) -> NSRect {
        switch mood {
        case .idle:
            return NSRect(x: 132, y: 116, width: 220, height: 96)
        case .scanning:
            return NSRect(x: 60, y: 116, width: 292, height: 184)
        case .alert:
            return NSRect(x: 16, y: 116, width: 336, height: 296)
        }
    }
}
