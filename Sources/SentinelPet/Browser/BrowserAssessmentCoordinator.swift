import Foundation

/// Model results remain native receipts. A fresh extension acknowledgement
/// presents them; only native avatar controls can resolve a held browser action.
@MainActor
final class BrowserAssessmentCoordinator {
    private let analyzer: LocalRiskAnalyzer
    private let modelReady: () -> Bool
    private let isDenied: (ScreenSnapshot) -> Bool
    private let onPresent: (BrowserRequest, RiskVerdict, ScreenSnapshot) -> Bool
    private let onProtectionChanged: (Bool) -> Void
    private let statusDetail: () -> String
    private let now: () -> Date
    private struct Receipt {
        let request: BrowserRequest
        let verdict: RiskVerdict
        let snapshot: ScreenSnapshot
        let date: Date
        let error: String?
        let decisionOverride: String?
        var decision: String { decisionOverride ?? BrowserAssessmentCoordinator.decision(for: verdict) }
        var isAction: Bool { request.action?.kind == "link" || request.action?.kind == "submit" }
        var canContinue: Bool {
            isAction && decision == "review" && (request.reason == nil || request.reason == "unavailable")
        }
    }
    private enum ActionState: String { case pending, stay, `continue` }
    private struct PendingDecision {
        let receipt: Receipt
        let date: Date
        var state: ActionState
    }
    private var receipts: [String: Receipt] = [:]
    // Retain only redacted, model-confirmed high findings briefly, so a fresh
    // browser action can repeat its warning after an earlier page alert closed.
    private var highFindings: [String: Receipt] = [:]
    private var decisions: [String: PendingDecision] = [:]
    private var activeIDs = Set<String>()
    private var activeChecks: [String: Task<RiskVerdict, Error>] = [:]
    // Independent native-host connections can deliver a cancellation just
    // before its original assessment. Keep only bounded, short-lived IDs.
    private var cancelledChecks: [String: Date] = [:]
    private(set) var completedCount = 0
    private var lastAssessment: BrowserResponse.AssessmentMetadata?

    init(analyzer: LocalRiskAnalyzer = LocalRiskAnalyzer(), modelReady: @escaping () -> Bool,
         isDenied: @escaping (ScreenSnapshot) -> Bool = { _ in false },
         statusDetail: @escaping () -> String = { "Text checks stay on this Mac. Visual checks require the screenshot button." },
         now: @escaping () -> Date = Date.init,
         onProtectionChanged: @escaping (Bool) -> Void = { _ in },
         onPresent: @escaping (BrowserRequest, RiskVerdict, ScreenSnapshot) -> Bool = { _,_,_ in true }) {
        self.analyzer = analyzer; self.modelReady = modelReady; self.isDenied = isDenied
        self.statusDetail = statusDetail; self.now = now; self.onPresent = onPresent
        self.onProtectionChanged = onProtectionChanged
    }

    func canContinue(assessmentID: String) -> Bool {
        prune()
        guard let decision = decisions[assessmentID], decision.state == .pending else { return false }
        return decision.receipt.canContinue
    }
    /// A later dismissal after Continue cannot overwrite the terminal choice.
    @discardableResult
    func resolve(assessmentID: String, continueOnce: Bool) -> Bool {
        prune()
        guard var decision = decisions[assessmentID], decision.state == .pending,
              !continueOnce || decision.receipt.canContinue else { return false }
        decision.state = continueOnce ? .continue : .stay
        decisions[assessmentID] = decision
        return true
    }

    func handle(_ raw: BrowserRequest) async -> BrowserResponse {
        let request: BrowserRequest
        do { request = try raw.validated() }
        catch { return .failure(id: raw.id, mode: raw.mode, message: error.localizedDescription) }
        let result = await handleValidated(request)
        if request.type == "assess", result.actionState != "stay" {
            lastAssessment = BrowserResponse.AssessmentMetadata(id: request.id,
                kind: request.action?.kind ?? "page", riskLevel: result.riskLevel,
                ok: result.ok, completedAt: Int64(now().timeIntervalSince1970 * 1_000))
        }
        return result
    }

    private func handleValidated(_ request: BrowserRequest) async -> BrowserResponse {
        prune()
        if request.type == "protection-state", let enabled = request.protectionEnabled {
            // Repeated true messages renew the native awake lease. This is
            // protection metadata, not a model operation or page assessment.
            onProtectionChanged(enabled)
            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                summary: enabled ? "Browser protection is active." : "Browser protection is paused.",
                guidance: "Muse received the browser protection state.")
        }
        if request.type == "status" {
            let ready = modelReady()
            return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                summary: ready ? "Muse Guard is connected to the local model." : "Muse Guard is connected; the model is still starting.",
                guidance: statusDetail(), mode: request.mode, modelReady: ready,
                lastAssessment: lastAssessment, completedAssessments: completedCount)
        }
        if request.type == "present-block" {
            guard let id = request.assessmentID, let finding = highFindings[id],
                  finding.error == nil, finding.verdict.riskLevel == .high,
                  finding.decision == "block", decisions[request.id] == nil else { return expired(request) }
            // Give each presentation its own native decision ID. Reusing the
            // original finding ID could let dismissal of an old bubble cancel
            // a newer one. This path never creates an override for a high risk.
            let original = finding.request
            let displayRequest = BrowserRequest(id: request.id, type: original.type, mode: original.mode,
                page: original.page, action: original.action, reason: original.reason, purpose: original.purpose)
            let display = Receipt(request: displayRequest, verdict: finding.verdict, snapshot: finding.snapshot,
                date: now(), error: nil, decisionOverride: nil)
            if display.isAction {
                decisions[request.id] = PendingDecision(receipt: display, date: now(), state: .pending)
                boundDecisions()
            }
            guard onPresent(display.request, display.verdict, display.snapshot) else {
                decisions.removeValue(forKey: request.id)
                return expired(request)
            }
            return response(request, receipt: display, elapsed: 0, actionState: display.isAction ? "pending" : nil)
        }
        if request.type == "finish-checking" {
            // Atomically hand progress ownership back to the extension. A
            // previously accepted Stay must win over a late safe model result.
            guard let id = request.assessmentID, let decision = decisions[id],
                  decision.receipt.request.reason == "checking" else { return expired(request) }
            decisions.removeValue(forKey: id)
            return response(request, receipt: decision.receipt, elapsed: 0, actionState: decision.state.rawValue)
        }
        if request.type == "decision" {
            guard let id = request.assessmentID, let decision = decisions[id] else { return expired(request) }
            if decision.state != .pending { decisions.removeValue(forKey: id) }
            return response(request, receipt: decision.receipt, elapsed: 0, actionState: decision.state.rawValue)
        }
        if request.type == "cancel" {
            guard let id = request.assessmentID else { return expired(request) }
            if let check = activeChecks[id] {
                // Cancelling a document also releases queued scheduler work
                // and its HTTP request. It never dismisses a native warning
                // or turns an unfinished assessment into permission to act.
                rememberCancellation(id)
                check.cancel()
                return BrowserResponse(id: request.id, ok: true, decision: "review", riskLevel: "unknown",
                    summary: "This browser check was cancelled.", guidance: "No browser action was cleared.", actionState: "stay")
            }
            if let receipt = receipts.removeValue(forKey: id) {
                return response(request, receipt: receipt, elapsed: 0, actionState: "stay")
            }
            guard var decision = decisions[id] else {
                rememberCancellation(id)
                return expired(request)
            }
            // An explicit browser cancellation revokes an unread choice. A
            // native UI dismissal uses resolve(false), which cannot do this.
            decision.state = .stay; decisions[id] = decision
            return response(request, receipt: decision.receipt, elapsed: 0, actionState: "stay")
        }
        if request.type == "present" {
            guard let id = request.assessmentID, let receipt = receipts.removeValue(forKey: id) else {
                return expired(request)
            }
            if receipt.isAction {
                decisions[id] = PendingDecision(receipt: receipt, date: now(), state: .pending)
                boundDecisions()
            }
            guard onPresent(receipt.request, receipt.verdict, receipt.snapshot) else {
                decisions.removeValue(forKey: id)
                return expired(request)
            }
            return response(request, receipt: receipt, elapsed: 0, actionState: receipt.isAction ? "pending" : nil)
        }
        guard let page = request.page else { return .failure(id: request.id, mode: request.mode, message: "The browser request has no page evidence.") }
        if request.type == "assess", cancelledChecks[request.id] != nil {
            return .failure(id: request.id, mode: request.mode, message: "This browser check was cancelled before it started. No action was cleared.", actionState: "stay")
        }
        // Never replace another request's receipt, decision or in-flight ID.
        guard !activeIDs.contains(request.id), receipts[request.id] == nil, decisions[request.id] == nil else {
            return .failure(id: request.id, mode: request.mode, message: "A check with this identifier already exists.")
        }
        if request.type == "notice" { return notice(request, page: page) }
        guard modelReady() else {
            return rememberFailure(request, page: page, message: "The local model is not ready. Keep this action paused and try again when Muse is ready.")
        }
        guard activeIDs.count < 6 else {
            return rememberFailure(request, page: page, message: "The local queue is full. This action has not been cleared; try again.")
        }
        let snapshot = Self.snapshot(for: request, page: page)
        guard !isDenied(snapshot) else {
            return rememberFailure(request, page: page, message: "This page matches your native privacy deny list and was not analyzed.")
        }
        activeIDs.insert(request.id)
        defer { activeIDs.remove(request.id); activeChecks.removeValue(forKey: request.id) }
        let start = now()
        let priority = Self.priority(for: request)
        let check = Task { [analyzer] in
            try await withThrowingTaskGroup(of: RiskVerdict.self) { group in
                group.addTask {
                    if let screenshot = request.screenshot {
                        return try await analyzer.analyze(snapshot: snapshot, screenshotDataURL: screenshot, model: LocalModelConfiguration.model, priority: priority)
                    }
                    return try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model, priority: priority, directAnswer: true)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: request.mode == "vision" ? 55_000_000_000 : 25_000_000_000)
                    throw BrowserCheckError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        activeChecks[request.id] = check
        do {
            let verdict = try await withTaskCancellationHandler(operation: { try await check.value }, onCancel: { check.cancel() })
            try Task.checkCancellation()
            guard !check.isCancelled else { throw CancellationError() }
            let receipt = remember(request, verdict: verdict)
            if verdict.riskLevel == .high {
                highFindings[request.id] = receipt
                if highFindings.count > 64, let oldest = highFindings.min(by: { $0.value.date < $1.value.date })?.key {
                    highFindings.removeValue(forKey: oldest)
                }
            }
            completedCount += 1
            return response(request, receipt: receipt, elapsed: now().timeIntervalSince(start))
        } catch {
            if check.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                // No receipt/high finding, completion counter or last-result
                // diagnostic is created for obsolete, cancelled evidence.
                return .failure(id: request.id, mode: request.mode,
                    message: "This scan was cancelled or superseded. No browser action was cleared.", actionState: "stay")
            }
            return rememberFailure(request, page: page, message: error.localizedDescription)
        }
    }

    static func priority(for request: BrowserRequest) -> LocalInferenceScheduler.Priority {
        if request.purpose != nil {
            // Real sensitive-field intent takes precedence over routine scans,
            // but must not cancel an equally important ongoing user chat.
            return request.purpose == "intent" && request.action?.kind == "submit" && request.action?.sensitive == true ? .interactive : .background
        }
        return request.action?.kind == "link" || request.action?.kind == "submit" ? .browserAction : .interactive
    }

    private func notice(_ request: BrowserRequest, page: BrowserRequest.Page) -> BrowserResponse {
        let summary: String, guidance: String
        switch request.reason {
        case "checking":
            let verdict = RiskVerdict(riskLevel: .unknown,
                summary: "I’ve paused this action while I check the page and destination.",
                guidance: "Checking locally on this Mac.", categories: ["browser_checking"])
            return response(request, receipt: remember(request, verdict: verdict), elapsed: 0)
        case "changed":
            summary = "The page changed before this action could be checked."
            guidance = "Stay here and choose the action again on the current page."
        case "unsupported":
            summary = "Muse cannot safely resume this browser action."
            guidance = "This action stays paused. Use a normal link or form on the current page."
        case "open_failed":
            summary = "Chrome could not open the checked destination."
            guidance = "Stay here and try opening the destination again."
        default:
            summary = "Muse could not finish this browser check."
            guidance = "This action has not been cleared. Stay here, or continue once after reviewing it yourself."
        }
        let verdict = RiskVerdict(riskLevel: .unknown, summary: summary, guidance: guidance, categories: ["browser_"+(request.reason ?? "unavailable")])
        let override = request.reason == "unavailable" ? "review" : "block"
        let receipt = remember(request, verdict: verdict, error: guidance, decisionOverride: override)
        return response(request, receipt: receipt, elapsed: 0)
    }
    private func rememberFailure(_ request: BrowserRequest, page: BrowserRequest.Page, message: String) -> BrowserResponse {
        let verdict = RiskVerdict(riskLevel: .unknown, summary: "Muse could not check this action.", guidance: message, categories: ["unassessed"])
        let receipt = remember(request, verdict: verdict, error: message)
        return response(request, receipt: receipt, elapsed: 0)
    }
    private func remember(_ request: BrowserRequest, verdict: RiskVerdict, error: String? = nil, decisionOverride: String? = nil) -> Receipt {
        let metadata = BrowserRequest(id: request.id, type: request.type, mode: request.mode,
            page: request.page.map { BrowserRequest.Page(url: $0.url, title: $0.title, text: "") }, action: request.action, reason: request.reason, purpose: request.purpose)
        let receipt = Receipt(request: metadata, verdict: verdict,
            snapshot: ScreenSnapshot(appName: "Google Chrome", windowTitle: request.page?.title, text: ""),
            date: now(), error: error, decisionOverride: decisionOverride)
        receipts[request.id] = receipt
        if receipts.count > 64, let oldest = receipts.min(by: { $0.value.date < $1.value.date })?.key { receipts.removeValue(forKey: oldest) }
        return receipt
    }
    private func prune() {
        let date = now()
        receipts = receipts.filter { date.timeIntervalSince($0.value.date) < 15 }
        highFindings = highFindings.filter { date.timeIntervalSince($0.value.date) < 60 }
        decisions = decisions.filter { date.timeIntervalSince($0.value.date) < 120 }
        cancelledChecks = cancelledChecks.filter { date.timeIntervalSince($0.value) < 120 }
    }
    private func rememberCancellation(_ id: String) {
        cancelledChecks[id] = now()
        if cancelledChecks.count > 128, let oldest = cancelledChecks.min(by: { $0.value < $1.value })?.key {
            cancelledChecks.removeValue(forKey: oldest)
        }
    }
    private func boundDecisions() {
        if decisions.count > 64, let oldest = decisions.min(by: { $0.value.date < $1.value.date })?.key { decisions.removeValue(forKey: oldest) }
    }
    private func expired(_ request: BrowserRequest) -> BrowserResponse {
        .failure(id: request.id, mode: request.mode, message: "That browser action has expired. Choose the action again on the current page.", actionState: "expired")
    }
    static func snapshot(for request: BrowserRequest, page: BrowserRequest.Page) -> ScreenSnapshot {
        var evidence: [String: Any] = ["page_url": page.url, "page_title": page.title,
            "visible_page_text": String(page.text.prefix(6_000)), "analysis_mode": request.mode,
            "limitations": "No cookies, passwords, entered field values, URL query strings or live reputation checks were supplied."]
        if let action = request.action {
            evidence["pending_action"] = ["kind": action.kind, "destination_url": action.url ?? page.url,
                "label": action.label ?? "", "method": action.method ?? "GET", "has_sensitive_fields": action.sensitive ?? false] as [String: Any]
        }
        let data = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])) ?? Data()
        return ScreenSnapshot(appName: "Google Chrome", windowTitle: page.title, text: String(data: data, encoding: .utf8) ?? "No readable browser evidence.")
    }
    nonisolated private static func decision(for verdict: RiskVerdict) -> String {
        switch verdict.riskLevel {
        case .safe, .low: return "allow"
        case .high: return "block"
        case .medium, .unknown: return "review"
        }
    }
    private func response(_ request: BrowserRequest, receipt: Receipt, elapsed: TimeInterval, actionState: String? = nil) -> BrowserResponse {
        BrowserResponse(id: request.id, ok: receipt.error == nil, decision: receipt.decision, riskLevel: receipt.verdict.riskLevel.rawValue,
            summary: receipt.verdict.summary, guidance: receipt.verdict.guidance, categories: receipt.verdict.categories,
            mode: receipt.request.mode, durationMS: Int(max(0, elapsed) * 1_000), error: receipt.error, actionState: actionState)
    }
    enum BrowserCheckError: LocalizedError {
        case timedOut
        var errorDescription: String? { "The local check timed out. Keep this action paused and retry, or review it yourself." }
    }
}
