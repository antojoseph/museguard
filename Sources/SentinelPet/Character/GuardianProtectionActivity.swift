import Foundation

/// Browser protection is an on-duty session, separate from model inference.
/// A bounded lease clears the on-duty indicator after Chrome disconnects.
@MainActor
final class GuardianProtectionActivity {
    private(set) var isActive = false
    private var explicitStateReceived = false
    private let duration: TimeInterval
    private let onChange: (Bool) -> Void
    private var expiry: Task<Void, Never>?
    private var generation = 0

    init(duration: TimeInterval = 90, onChange: @escaping (Bool) -> Void) {
        self.duration = duration
        self.onChange = onChange
    }
    func update(enabled: Bool) {
        explicitStateReceived = true
        renew(enabled)
    }
    /// Existing development content scripts can keep protection awake until
    /// their first explicit heartbeat arrives. A later Pause always wins.
    func refreshFromAutomaticCheck() {
        guard !explicitStateReceived else { return }
        renew(true)
    }
    private func renew(_ enabled: Bool) {
        generation += 1
        let token = generation
        expiry?.cancel(); expiry = nil
        setActive(enabled)
        guard enabled else { return }
        expiry = Task { [weak self, duration] in
            try? await Task.sleep(nanoseconds:UInt64(max(0,duration)*1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.expiry = nil
            self.explicitStateReceived = false
            self.setActive(false)
        }
    }
    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange(active)
    }
    deinit { expiry?.cancel() }
}
