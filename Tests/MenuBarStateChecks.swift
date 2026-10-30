import Combine
import Foundation

@MainActor private final class MenuInputs: ObservableObject {
    @Published var status = "Monitoring on"
    @Published var paused = false
    @Published var hidden = false
    @Published var acknowledgment = false
    @Published var rendererReady = true
    @Published var frame = 0
    @Published var recentChecks = 0
}

@main struct MenuBarStateChecks {
    @MainActor static func main() {
        let inputs = MenuInputs()
        let menu = MenuBarState(status: inputs.$status.eraseToAnyPublisher(),
            paused: inputs.$paused.eraseToAnyPublisher(), hidden: inputs.$hidden.eraseToAnyPublisher(),
            acknowledgment: inputs.$acknowledgment.eraseToAnyPublisher(),
            rendererReady: inputs.$rendererReady.eraseToAnyPublisher())
        assert(menu.snapshot.monitoringStatus == "Monitoring on" && menu.snapshot.rendererReady)
        var menuUpdates = 0
        var sourceUpdates = 0
        let menuSubscription = menu.objectWillChange.sink { menuUpdates += 1 }
        let sourceSubscription = inputs.objectWillChange.sink { sourceUpdates += 1 }

        // Renderer frames and background checks continue while a native menu
        // tracks the pointer. Neither may reconstruct its hovered submenu.
        for frame in 1...600 {
            inputs.frame = frame
            inputs.recentChecks = frame
            inputs.status = "Monitoring on"
            inputs.rendererReady = true
            inputs.paused = false
        }
        assert(sourceUpdates == 3_000)
        assert(menuUpdates == 0, "Frame/check traffic and repeated values must leave the native menu untouched.")

        inputs.paused = true
        assert(menuUpdates == 1 && menu.snapshot.monitoringPaused)
        inputs.status = "Monitoring paused"
        assert(menuUpdates == 2 && menu.snapshot.monitoringStatus == "Monitoring paused")
        inputs.hidden = true
        assert(menuUpdates == 3 && menu.snapshot.avatarHidden)
        inputs.acknowledgment = true
        assert(menuUpdates == 4 && menu.snapshot.hasAcknowledgment)
        inputs.rendererReady = false
        assert(menuUpdates == 5 && !menu.snapshot.rendererReady)
        for _ in 0..<100 { inputs.acknowledgment = true; inputs.hidden = true }
        assert(menuUpdates == 5)
        withExtendedLifetime([menuSubscription, sourceSubscription]) {}
        print("PASS: native menu ignores frame/check churn and duplicate values, while real menu choices update once")
    }
}
