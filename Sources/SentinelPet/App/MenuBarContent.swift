import SwiftUI
import AppKit
import Combine

/// Everyday actions stay here; setup and recovery live in Settings.
@MainActor
struct MenuBarContent: View {
    @StateObject private var menu: MenuBarState
    private let runtime: SentinelPetRuntime

    init() {
        let runtime = SentinelPetRuntime.shared
        self.runtime = runtime
        #if MUSE_DEVELOPMENT
        let rendererReady = UnrealCharacterRenderer.shared.$isReady.eraseToAnyPublisher()
        #else
        let rendererReady = Just(false).eraseToAnyPublisher()
        #endif
        _menu = StateObject(wrappedValue: MenuBarState(
            status: runtime.$monitoringStatus.eraseToAnyPublisher(),
            paused: runtime.$monitoringPaused.eraseToAnyPublisher(),
            hidden: runtime.petViewModel.$isAvatarHidden.eraseToAnyPublisher(),
            acknowledgment: runtime.petViewModel.$acknowledgment.map { $0 != nil }.eraseToAnyPublisher(),
            rendererReady: rendererReady))
    }

    var body: some View {
        Text("Muse Guard").font(.headline)
        Label(menu.snapshot.monitoringStatus, systemImage: menu.snapshot.monitoringPaused ? "pause.circle" : "shield.lefthalf.filled")
        Button("Ask Muse…") { runtime.openPetChat() }
        if menu.snapshot.monitoringPaused {
            Button("Resume monitoring") { runtime.resumeMonitoring() }
        } else {
            Menu("Pause monitoring") {
                Button("For 30 minutes") { runtime.pauseMonitoring(for: 30 * 60) }
                Button("Until I resume") { runtime.pauseMonitoring(for: 0) }
            }
        }
        Divider()
        Button(menu.snapshot.avatarHidden ? "Show Muse" : "Hide Muse") { runtime.toggleAvatarVisibility() }
        Button("Return Muse home") { runtime.returnMuseHome() }
            .disabled(menu.snapshot.hasAcknowledgment)
        Button("Recent activity…") { runtime.showAnalysisLogs() }
        Button("Settings…") { runtime.showSettings() }
        #if MUSE_DEVELOPMENT
        Divider()
        Menu("Development") {
            Button("Open Muse Studio…") { GuardianStudio.shared.show() }
            Button("Preview guard intervention") { runtime.previewGuardianIntervention() }
                .disabled(!menu.snapshot.rendererReady || menu.snapshot.avatarHidden || menu.snapshot.hasAcknowledgment)
            Button("Open mock lab…") { MockLab.shared.show() }
        }
        #endif
        Divider()
        Button("Quit Muse Guard") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
