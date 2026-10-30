import Combine
import Foundation

/// One persisted switch owns every automatic check. Chrome mirrors this state;
/// its heartbeat can never override a newer native Pause or Resume.
@MainActor
final class MonitoringControl: ObservableObject {
    static let shared = MonitoringControl()
    @Published private(set) var state: BrowserResponse.MonitoringState
    @Published private(set) var browserAcknowledgedRevision: Int64 = 0
    @Published private(set) var browserConnected = false
    private let defaults: UserDefaults
    private let now: () -> Date
    private var expiry: Task<Void, Never>?
    private var connectionExpiry: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        let revision = max(1, Int64(defaults.double(forKey: "monitoringControlRevision")))
        let paused = defaults.bool(forKey: "monitoringControlPaused")
        let until = Int64(defaults.double(forKey: "monitoringControlPauseUntil"))
        self.state = .init(paused: paused, pauseUntil: paused ? max(0, until) : 0, revision: revision)
        reconcileExpiry()
        scheduleExpiry()
    }

    var isPaused: Bool { reconcileExpiry(); return state.paused }
    var browserIsSynchronized: Bool { browserAcknowledgedRevision == state.revision }
    var syncPending: Bool { !browserIsSynchronized }

    func pause(for seconds: TimeInterval = 0) {
        let duration = seconds > 0 ? 1_800.0 : 0
        update(paused: true, until: duration > 0 ? Int64((now().timeIntervalSince1970 + duration) * 1_000) : 0)
    }
    func resume() { update(paused: false, until: 0) }

    func handle(_ raw: BrowserRequest) -> BrowserResponse? {
        guard ["monitoring-state", "monitoring-control"].contains(raw.type) else { return nil }
        let request: BrowserRequest
        do { request = try raw.validated() }
        catch { return .failure(id: raw.id, message: error.localizedDescription) }
        browserConnected = true
        connectionExpiry?.cancel()
        connectionExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.browserConnected = false
        }
        reconcileExpiry()
        if request.type == "monitoring-control" {
            if let expected = request.monitoringRevision, expected != state.revision {
                return BrowserResponse(id: request.id, ok: false, decision: "review", riskLevel: "unknown",
                    summary: "Monitoring changed elsewhere.", guidance: "The newer monitoring setting was kept. Try again.",
                    error: "Monitoring changed elsewhere. Try again.", monitoring: state)
            }
            if request.monitoringCommand == "resume" { resume() }
            else { pause(for: request.pauseDurationMS == 1_800_000 ? 1_800 : 0) }
        }
        if request.type == "monitoring-state" {
            browserAcknowledgedRevision = request.monitoringRevision == state.revision ? state.revision : 0
        }
        return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
            summary: state.paused ? "Monitoring is paused." : "Monitoring is enabled.",
            guidance: "This setting applies to browser protection and desktop screen checks.", monitoring: state)
    }

    private func update(paused: Bool, until: Int64) {
        expiry?.cancel(); expiry = nil
        let revision = max(state.revision + 1, Int64(now().timeIntervalSince1970 * 1_000))
        state = .init(paused: paused, pauseUntil: until, revision: revision)
        defaults.set(paused, forKey: "monitoringControlPaused")
        defaults.set(Double(until), forKey: "monitoringControlPauseUntil")
        defaults.set(Double(revision), forKey: "monitoringControlRevision")
        scheduleExpiry()
    }
    private func reconcileExpiry() {
        if state.paused, state.pauseUntil > 0, state.pauseUntil <= Int64(now().timeIntervalSince1970 * 1_000) { resume() }
    }
    private func scheduleExpiry() {
        guard state.paused, state.pauseUntil > 0 else { return }
        let revision = state.revision
        let delay = max(0, Double(state.pauseUntil) / 1_000 - now().timeIntervalSince1970)
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state.revision == revision else { return }
            self.reconcileExpiry()
        }
    }
    deinit { expiry?.cancel(); connectionExpiry?.cancel() }
}
