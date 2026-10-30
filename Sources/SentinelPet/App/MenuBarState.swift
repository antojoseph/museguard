import Combine

/// Native menus keep tracking the hovered item only while their contents stay
/// stable. Observe menu choices, never the renderer's frames or activity log.
@MainActor
final class MenuBarState: ObservableObject {
    struct Snapshot: Equatable {
        var monitoringStatus = "Starting monitoring…"
        var monitoringPaused = false
        var avatarHidden = false
        var hasAcknowledgment = false
        var rendererReady = false
    }

    @Published private(set) var snapshot = Snapshot()
    private var subscription: AnyCancellable?

    init(status: AnyPublisher<String, Never>, paused: AnyPublisher<Bool, Never>,
         hidden: AnyPublisher<Bool, Never>, acknowledgment: AnyPublisher<Bool, Never>,
         rendererReady: AnyPublisher<Bool, Never>) {
        subscription = Publishers.CombineLatest4(status.removeDuplicates(), paused.removeDuplicates(),
            hidden.removeDuplicates(), acknowledgment.removeDuplicates())
            .combineLatest(rendererReady.removeDuplicates())
            .map { values, ready in
                Snapshot(monitoringStatus: values.0, monitoringPaused: values.1,
                    avatarHidden: values.2, hasAcknowledgment: values.3, rendererReady: ready)
            }
            .removeDuplicates()
            .sink { [weak self] snapshot in
                guard self?.snapshot != snapshot else { return }
                self?.snapshot = snapshot
            }
    }
}
