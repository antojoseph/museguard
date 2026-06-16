import AppKit
import SwiftUI

/// Creates and manages the floating pet panel and its SwiftUI content.
@MainActor
final class PetOverlayController {
    private var panel: PetPanel?
    private let viewModel = PetViewModel()
    private var moveObserver: NSObjectProtocol?

    /// Total content size: enough vertical room for a speech bubble above the
    /// pet, which sits anchored at the bottom-trailing corner.
    private let contentSize = NSSize(width: 236, height: 256)

    func show() {
        let hosting = NSHostingView(rootView: PetRootView(viewModel: viewModel))
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
