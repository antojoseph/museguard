import Foundation

/// Smooth short gaps between model jobs without changing the avatar's pose,
/// idle clock, visibility or warning state.
@MainActor
final class GuardianWorkActivity {
    private(set) var isActive = false
    private(set) var isWorking = false
    private let delay: TimeInterval
    private let minimumDuration: TimeInterval
    private let settlingDelay: TimeInterval
    private let onChange: (Bool) -> Void
    private var visibleSince = Date.distantPast
    private var generation = 0
    private var transition: Task<Void, Never>?

    init(delay: TimeInterval = 0.2, minimumDuration: TimeInterval = 1.5,
         settlingDelay: TimeInterval = 0.25, onChange: @escaping (Bool) -> Void) {
        self.delay = delay
        self.minimumDuration = minimumDuration
        self.settlingDelay = settlingDelay
        self.onChange = onChange
    }

    func setWorking(_ working: Bool) {
        guard isWorking != working else { return }
        isWorking = working
        generation += 1
        let token = generation
        transition?.cancel()
        transition = nil
        if working && isActive { return }
        if !working && !isActive { return }
        let wait = working ? delay : max(settlingDelay, minimumDuration - Date().timeIntervalSince(visibleSince))
        transition = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == token, self.isWorking == working else { return }
            self.transition = nil
            self.isActive = working
            if working { self.visibleSince = Date() }
            self.onChange(working)
        }
    }

    deinit { transition?.cancel() }
}
