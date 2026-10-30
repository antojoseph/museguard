import Foundation

struct BrowserChatContext {
    let page: BrowserRequest.Page
    let tabID: Int
    let windowID: Int
    /// Opaque content-script document identity; never sent to the model.
    let documentID: String
}

/// A short-lived mailbox for an explicit native chat question. Chrome supplies
/// one fresh public-text snapshot, then the broker releases all request state.
@MainActor
final class BrowserChatContextBroker {
    private struct Pending {
        let deadline: Date
        let continuation: CheckedContinuation<BrowserChatContext,Error>
        let timeout: Task<Void,Never>
    }
    private var pending: [String:Pending] = [:]
    private var order: [String] = []
    private let timeout: TimeInterval
    private let now: () -> Date

    init(timeout: TimeInterval = 6, now: @escaping () -> Date = Date.init) {
        self.timeout = min(6,max(0.001,timeout)); self.now = now
    }

    func requestContext(timeout requestedTimeout: TimeInterval? = nil) async throws -> BrowserChatContext {
        let id = UUID().uuidString
        let requestTimeout = min(timeout, max(0.001, requestedTimeout ?? timeout))
        let context = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            prune()
            guard pending.count < 4 else { throw ContextError.busy }
            return try await withCheckedThrowingContinuation { continuation in
                let deadline = now().addingTimeInterval(requestTimeout)
                let timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds:UInt64(requestTimeout*1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(id,result:.failure(ContextError.timedOut))
                }
                pending[id] = Pending(deadline:deadline,continuation:continuation,timeout:timer)
                order.append(id)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id,result:.failure(CancellationError())) }
        })
        try Task.checkCancellation()
        return context
    }

    /// Return nil for other protocol routes so Runtime can pass them onward.
    func handle(_ raw: BrowserRequest) -> BrowserResponse? {
        guard raw.type == "chat-context-poll" || raw.type == "chat-context-result" else { return nil }
        let request: BrowserRequest
        do { request = try raw.validated() }
        catch {
            if raw.type == "chat-context-result", let id = raw.contextRequestID, pending[id] != nil {
                finish(id,result:.failure(ContextError.invalidContext))
            }
            return .failure(id:raw.id,message:BrowserProtocolError.invalidRequest.localizedDescription)
        }
        prune()
        if request.type == "chat-context-poll" {
            let id = order.first
            return BrowserResponse(id:request.id,ok:true,decision:"review",riskLevel:"unknown",
                summary:"Browser chat context mailbox.",guidance:"No automatic analysis was requested.",
                contextRequestID:id,contextExpiresAt:id.flatMap { pending[$0].map { Int64($0.deadline.timeIntervalSince1970*1_000) } })
        }
        guard let id = request.contextRequestID, pending[id] != nil else {
            return .failure(id:request.id,message:ContextError.expired.localizedDescription)
        }
        if request.contextError != nil {
            finish(id,result:.failure(ContextError.unavailable))
        } else if let page = request.page, let tabID = request.tabID, let windowID = request.windowID, let documentID = request.documentID {
            finish(id,result:.success(BrowserChatContext(page:page,tabID:tabID,windowID:windowID,documentID:documentID)))
        } else {
            finish(id,result:.failure(ContextError.invalidContext))
            return .failure(id:request.id,message:ContextError.invalidContext.localizedDescription)
        }
        return BrowserResponse(id:request.id,ok:true,decision:"review",riskLevel:"unknown",
            summary:"Browser chat context reply received.",guidance:"The one-time request has been consumed.")
    }

    private func finish(_ id: String, result: Result<BrowserChatContext,Error>) {
        guard let request = pending.removeValue(forKey:id) else { return }
        order.removeAll { $0 == id }
        request.timeout.cancel()
        request.continuation.resume(with:result)
    }
    private func prune() {
        let expired = pending.filter { $0.value.deadline <= now() }.map(\.key)
        for id in expired { finish(id,result:.failure(ContextError.timedOut)) }
    }
    deinit {
        for request in pending.values {
            request.timeout.cancel(); request.continuation.resume(throwing:CancellationError())
        }
    }

    enum ContextError: LocalizedError {
        case busy, timedOut, expired, unavailable, invalidContext
        var errorDescription: String? {
            switch self {
            case .busy: return "A few browser questions are already waiting. Try again shortly."
            case .timedOut: return "Chrome did not provide fresh page context in time. Try again on the page you want to discuss."
            case .expired: return "This browser context request is no longer current."
            case .unavailable: return "Chrome could not read this page. Open a normal web page and try again."
            case .invalidContext: return "Chrome returned incomplete page context. Try again on the current page."
            }
        }
    }
}
