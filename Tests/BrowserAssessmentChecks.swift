import Foundation

private final class ModelFixture: URLProtocol {
    static var risk = "high"
    static var malformed = false
    static var calls = 0
    static var directCalls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            requestBody = bytes
        }
        if let data = requestBody, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = body["messages"] as? [[String: Any]], messages.last?["role"] as? String == "assistant",
           messages.last?["content"] as? String == "{", body["max_tokens"] as? Int == 512 { Self.directCalls += 1 }
        let verdict: [String: Any] = ["risk_level": Self.risk, "summary": "The destination asks for an authenticator code.",
            "guidance": "Use your saved official bookmark.", "categories": ["credential_theft"]]
        let content = Self.malformed ? "not a verdict" : String(data: try! JSONSerialization.data(withJSONObject: verdict), encoding: .utf8)!
        let payload: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor Events {
    private var values: [String] = []
    func add(_ value: String) { values.append(value) }
    func contains(_ value: String) -> Bool { values.contains(value) }
}

@main struct BrowserAssessmentChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFixture.self]
        let analyzer = LocalRiskAnalyzer(session: URLSession(configuration: config))
        var presentations = 0
        var presented: [BrowserRequest] = []
        var testNow = Date()
        let coordinator = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { true }, now: { testNow },
            onPresent: { request,_,_ in presentations += 1; presented.append(request); return true })
        let page = BrowserRequest.Page(url: "https://account-check.example.test/login?token=private#secret", title: "Account check", text: "Enter a password and one-time code to stop deletion.")
        let action = BrowserRequest.Action(kind: "submit", url: "https://account-check.example.test/post", label: "Verify", method: "POST", sensitive: true)
        func poll(_ owner: BrowserAssessmentCoordinator, _ id: String) async -> BrowserResponse {
            await owner.handle(BrowserRequest(id: UUID().uuidString, type: "decision", assessmentID: id))
        }
        func present(_ owner: BrowserAssessmentCoordinator, _ id: String) async -> BrowserResponse {
            await owner.handle(BrowserRequest(id: UUID().uuidString, type: "present", assessmentID: id))
        }
        let status = await coordinator.handle(BrowserRequest(id: "status", type: "status"))
        assert(status.ok && status.modelReady == true && ModelFixture.calls == 0)
        assert(status.lastAssessment == nil && status.completedAssessments == 0)
        var expectedCompletions = 0
        for (risk, expected) in [("high","block"),("medium","review"),("unknown","review"),("safe","allow"),("low","allow")] {
            ModelFixture.risk = risk
            let id = UUID().uuidString
            let result = await coordinator.handle(BrowserRequest(id: id, type: "assess", page: page, action: action))
            assert(result.ok && result.decision == expected && result.riskLevel == risk)
            assert(result.lastAssessment == nil && result.completedAssessments == nil, "Completion diagnostics are status-only.")
            expectedCompletions += 1
            let completed = await coordinator.handle(BrowserRequest(id: "completed-status", type: "status"))
            assert(completed.completedAssessments == expectedCompletions)
            assert(completed.lastAssessment?.id == id && completed.lastAssessment?.kind == "submit")
            assert(completed.lastAssessment?.riskLevel == risk && completed.lastAssessment?.ok == true)
            assert(completed.lastAssessment?.completedAt == Int64(testNow.timeIntervalSince1970 * 1_000))
            assert(presentations == 0, "No avatar presentation before extension context acknowledgement.")
            let shown = await present(coordinator, id)
            assert(shown.ok && shown.actionState == "pending")
            assert(shown.lastAssessment == nil && shown.completedAssessments == nil)
            assert(presented.last?.id == id && presented.last?.page?.text == "" && presented.last?.screenshot == nil)
            let repeated = await present(coordinator, id)
            assert(!repeated.ok && repeated.actionState == "expired")
            let pending = await poll(coordinator, id)
            assert(pending.actionState == "pending")
            let continuable = expected == "review"
            assert(coordinator.canContinue(assessmentID: id) == continuable)
            if continuable {
                assert(coordinator.resolve(assessmentID: id, continueOnce: true))
                assert(!coordinator.resolve(assessmentID: id, continueOnce: false), "UI dismissal cannot overwrite a terminal Continue.")
            } else {
                assert(!coordinator.resolve(assessmentID: id, continueOnce: true), "High risk cannot be overridden.")
                assert(coordinator.resolve(assessmentID: id, continueOnce: false))
            }
            let terminal = await poll(coordinator, id)
            assert(terminal.actionState == (continuable ? "continue" : "stay"))
            let consumed = await poll(coordinator, id)
            assert(consumed.actionState == "expired", "A terminal browser choice is delivered only once.")
            let afterControls = await coordinator.handle(BrowserRequest(id: "controls-status", type: "status"))
            assert(afterControls.lastAssessment?.id == id && afterControls.completedAssessments == expectedCompletions,
                "Presentation and decision traffic cannot replace the latest actual assessment.")
            presentations = 0
        }
        assert(ModelFixture.directCalls == 5, "Browser text checks use the bounded direct-answer request.")
        // Proactive high findings can be shown again on a later matching click,
        // even after the first native warning was dismissed. Each display has
        // its own decision ID and never grants a high-risk override.
        ModelFixture.risk = "high"
        let cachedHigh = await coordinator.handle(BrowserRequest(id: "cached-high", type: "assess", page: page, action: action))
        assert(cachedHigh.ok && cachedHigh.riskLevel == "high")
        _ = await present(coordinator, "cached-high")
        assert(coordinator.resolve(assessmentID: "cached-high", continueOnce: false))
        for displayID in ["high-display-one", "high-display-two"] {
            let shown = await coordinator.handle(BrowserRequest(id: displayID, type: "present-block", assessmentID: "cached-high"))
            assert(shown.ok && shown.decision == "block" && shown.actionState == "pending")
            assert(presented.last?.id == displayID && presented.last?.page?.text == "" && presented.last?.screenshot == nil)
            assert(!coordinator.canContinue(assessmentID: displayID))
            assert(!coordinator.resolve(assessmentID: displayID, continueOnce: true))
            assert(coordinator.resolve(assessmentID: displayID, continueOnce: false))
        }
        ModelFixture.risk = "low"
        _ = await coordinator.handle(BrowserRequest(id: "cached-low", type: "assess", page: page, action: action))
        let lowCannotBlock = await coordinator.handle(BrowserRequest(id: "low-display", type: "present-block", assessmentID: "cached-low"))
        assert(!lowCannotBlock.ok && lowCannotBlock.actionState == "expired")
        let cleaned = try BrowserRequest(id: "clean", type: "assess", page: page).validated()
        let evidence = BrowserAssessmentCoordinator.snapshot(for: cleaned, page: cleaned.page!)
        assert(!evidence.text.contains("token=private") && !evidence.text.contains("#secret"))
        assert(evidence.appName == "Google Chrome")
        let successesBeforeFailure = coordinator.completedCount
        ModelFixture.malformed = true
        let invalid = await coordinator.handle(BrowserRequest(id: "malformed", type: "assess", page: page, action: action))
        assert(!invalid.ok && invalid.decision == "review" && invalid.riskLevel == "unknown")
        let failureStatus = await coordinator.handle(BrowserRequest(id: "failure-status", type: "status"))
        assert(failureStatus.lastAssessment?.id == "malformed" && failureStatus.lastAssessment?.kind == "submit")
        assert(failureStatus.lastAssessment?.ok == false && failureStatus.lastAssessment?.riskLevel == "unknown")
        assert(failureStatus.completedAssessments == successesBeforeFailure, "Failures update metadata without incrementing successful completions.")
        let malformedCannotBlock = await coordinator.handle(BrowserRequest(id: "malformed-display", type: "present-block", assessmentID: "malformed"))
        assert(!malformedCannotBlock.ok && malformedCannotBlock.actionState == "expired")
        let malformedShown = await present(coordinator, "malformed")
        assert(!malformedShown.ok && malformedShown.actionState == "pending", "Model failures must remain presentable by the avatar.")
        ModelFixture.malformed = false
        let unavailable = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { false })
        let stopped = await unavailable.handle(BrowserRequest(id: "stopped", type: "assess", page: page, action: action))
        assert(!stopped.ok && stopped.decision == "review")
        let stoppedStatus = await unavailable.handle(BrowserRequest(id: "stopped-status", type: "status"))
        assert(stoppedStatus.completedAssessments == 0 && stoppedStatus.lastAssessment?.id == "stopped")
        assert(stoppedStatus.lastAssessment?.ok == false)
        let stoppedShown = await present(unavailable, "stopped")
        assert(stoppedShown.actionState == "pending" && unavailable.canContinue(assessmentID: "stopped"))
        assert(unavailable.resolve(assessmentID: "stopped", continueOnce: true))

        // One bounded record, rather than a history of browser evidence, is
        // sufficient to correlate a local prefetch result with a live test.
        let diagnostics = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { false }, now: { testNow })
        let boundedID = String(repeating: "a", count: 128)
        _ = await diagnostics.handle(BrowserRequest(id: boundedID, type: "assess", page: page))
        _ = await diagnostics.handle(BrowserRequest(id: "diagnostic-notice", type: "notice", page: page, action: action, reason: "checking"))
        _ = await present(diagnostics, "diagnostic-notice")
        _ = await diagnostics.handle(BrowserRequest(id: String(repeating: "b", count: 129), type: "assess", page: page))
        let privateStatus = await diagnostics.handle(BrowserRequest(id: "private-status", type: "status"))
        assert(privateStatus.lastAssessment?.id == boundedID && privateStatus.lastAssessment?.kind == "page")
        assert(privateStatus.completedAssessments == 0, "Notices and invalid transport requests are not completed model assessments.")
        let statusData = try JSONEncoder().encode(privateStatus)
        let statusJSON = try JSONSerialization.jsonObject(with: statusData) as! [String: Any]
        let lastJSON = statusJSON["last_assessment"] as! [String: Any]
        assert(Set(lastJSON.keys) == Set(["id", "kind", "risk_level", "ok", "completed_at"]))
        let encodedStatus = String(data: statusData, encoding: .utf8)!
        for evidence in ["account-check.example.test", "Account check", "Enter a password", "token=private", "Verify", "POST", "data:image", "sensitive"] {
            assert(!encodedStatus.contains(evidence), "Status must not retain page, field, action or image evidence.")
        }
        assert(statusData.count < 1024)
        let explicitOverride = await poll(unavailable, "stopped")
        assert(!explicitOverride.ok && explicitOverride.actionState == "continue", "Explicit user choice is distinct from model approval.")
        let denied = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { true }, isDenied: { _ in true })
        let skipped = await denied.handle(BrowserRequest(id: "denied", type: "assess", page: page, action: action))
        assert(!skipped.ok && skipped.decision == "review")
        let deniedShown = await present(denied, "denied")
        assert(deniedShown.actionState == "pending")

        // Notices never invoke the model, and their text/allowed action comes
        // from the native app rather than untrusted page-supplied messages.
        let callsBeforeNotices = ModelFixture.calls
        for reason in ["unavailable", "changed", "unsupported", "open_failed"] {
            let id = "notice-"+reason
            let result = await coordinator.handle(BrowserRequest(id: id, type: "notice", page: page, action: action, reason: reason))
            assert(!result.ok && result.decision == (reason == "unavailable" ? "review" : "block"))
            let shown = await present(coordinator, id)
            assert(shown.actionState == "pending" && presented.last?.reason == reason)
            assert(coordinator.canContinue(assessmentID: id) == (reason == "unavailable"))
            if reason != "unavailable" { assert(!coordinator.resolve(assessmentID: id, continueOnce: true)) }
            let cancelled = await coordinator.handle(BrowserRequest(id: UUID().uuidString, type: "cancel", assessmentID: id))
            assert(cancelled.actionState == "stay")
            let stayed = await poll(coordinator, id)
            assert(stayed.actionState == "stay")
        }
        let progress = await coordinator.handle(BrowserRequest(id: "progress", type: "notice", page: page,
            action: .init(kind: "page", url: page.url, label: nil, method: nil, sensitive: nil), reason: "checking"))
        assert(progress.ok && progress.summary == "I’ve paused this action while I check the page and destination.")
        let progressShown = await present(coordinator, "progress")
        assert(progressShown.actionState == nil && presented.last?.reason == "checking")
        // An in-progress held action is cancellable from Muse before the
        // model result arrives. It can never be continued from progress UI.
        for kind in ["link", "submit"] {
            let id = "progress-"+kind
            let held = BrowserRequest.Action(kind: kind, url: action.url, label: action.label,
                method: kind == "submit" ? "POST" : "GET", sensitive: true)
            let checkingAction = await coordinator.handle(BrowserRequest(id: id, type: "notice", page: page, action: held, reason: "checking"))
            assert(checkingAction.ok)
            let shown = await present(coordinator, id)
            assert(shown.actionState == "pending" && !coordinator.canContinue(assessmentID: id))
            assert(!coordinator.resolve(assessmentID: id, continueOnce: true))
            assert(coordinator.resolve(assessmentID: id, continueOnce: false))
            let stayed = await poll(coordinator, id)
            assert(stayed.actionState == "stay")
            let consumed = await poll(coordinator, id)
            assert(consumed.actionState == "expired")
        }
        assert(ModelFixture.calls == callsBeforeNotices)
        // Model completion and native Stay use one atomic progress handoff.
        // A missed polling interval cannot turn an already accepted Stay into
        // permission to replay a late safe result.
        for stayedFirst in [false, true] {
            let id = "handoff-"+String(stayedFirst)
            _ = await coordinator.handle(BrowserRequest(id: id, type: "notice", page: page, action: action, reason: "checking"))
            _ = await present(coordinator, id)
            if stayedFirst { assert(coordinator.resolve(assessmentID: id, continueOnce: false)) }
            let finished = await coordinator.handle(BrowserRequest(id: UUID().uuidString, type: "finish-checking", assessmentID: id))
            assert(finished.actionState == (stayedFirst ? "stay" : "pending"))
            assert(!coordinator.resolve(assessmentID: id, continueOnce: false), "The old progress UI cannot resolve after handoff.")
            let repeated = await coordinator.handle(BrowserRequest(id: UUID().uuidString, type: "finish-checking", assessmentID: id))
            assert(repeated.actionState == "expired")
        }
        _ = await coordinator.handle(BrowserRequest(id: "final-warning", type: "notice", page: page, action: action, reason: "unavailable"))
        _ = await present(coordinator, "final-warning")
        let wrongKind = await coordinator.handle(BrowserRequest(id: "wrong-handoff", type: "finish-checking", assessmentID: "final-warning"))
        assert(wrongKind.actionState == "expired")
        let preserved = await poll(coordinator, "final-warning")
        assert(preserved.actionState == "pending" && coordinator.canContinue(assessmentID: "final-warning"), "A progress handoff cannot remove a final warning.")
        assert(coordinator.resolve(assessmentID: "final-warning", continueOnce: false))

        let hidden = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { false }, onPresent: { _,_,_ in false })
        _ = await hidden.handle(BrowserRequest(id: "hidden", type: "assess", page: page, action: action))
        let rejected = await present(hidden, "hidden")
        assert(rejected.actionState == "expired" && !hidden.canContinue(assessmentID: "hidden"))
        let rejectedPoll = await poll(hidden, "hidden")
        assert(rejectedPoll.actionState == "expired")

        _ = await coordinator.handle(BrowserRequest(id: "receipt-expiry", type: "notice", page: page, action: action, reason: "unavailable"))
        testNow = testNow.addingTimeInterval(16)
        let expiredReceipt = await present(coordinator, "receipt-expiry")
        assert(expiredReceipt.actionState == "expired")
        let stillFreshHigh = await coordinator.handle(BrowserRequest(id: "high-display-after-first-receipt", type: "present-block", assessmentID: "cached-high"))
        assert(stillFreshHigh.ok && stillFreshHigh.riskLevel == "high", "A dismissed page warning does not erase its fresh high finding.")
        _ = await coordinator.handle(BrowserRequest(id: "decision-expiry", type: "notice", page: page, action: action, reason: "unavailable"))
        _ = await present(coordinator, "decision-expiry")
        testNow = testNow.addingTimeInterval(121)
        let expiredDecision = await poll(coordinator, "decision-expiry")
        assert(expiredDecision.actionState == "expired" && !coordinator.resolve(assessmentID: "decision-expiry", continueOnce: true))
        let expiredHigh = await coordinator.handle(BrowserRequest(id: "high-display-expired", type: "present-block", assessmentID: "cached-high"))
        assert(!expiredHigh.ok && expiredHigh.actionState == "expired", "Stale proactive findings cannot create new native warnings.")

        _ = await coordinator.handle(BrowserRequest(id: "cancel-before-present", type: "notice", page: page, action: action, reason: "unavailable"))
        let earlyCancel = await coordinator.handle(BrowserRequest(id: "cancel-early", type: "cancel", assessmentID: "cancel-before-present"))
        assert(earlyCancel.actionState == "stay")
        let cancelledPresentation = await present(coordinator, "cancel-before-present")
        assert(cancelledPresentation.actionState == "expired")

        // Automatic destination prefetch must not interrupt an explicit user
        // check, even when its descriptor happens to be a form submission.
        let priorityEvents = Events()
        let manualWork = Task {
            do {
                return try await LocalInferenceScheduler.shared.run(priority: .interactive) {
                    await priorityEvents.add("manual-start")
                    while !(await priorityEvents.contains("release")) {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    return "manual-complete"
                }
            } catch { await priorityEvents.add("manual-cancelled"); throw error }
        }
        while !(await priorityEvents.contains("manual-start")) { await Task.yield() }
        let callsBeforePrefetch = ModelFixture.calls
        let automatic = Task { @MainActor in
            await coordinator.handle(BrowserRequest(id: "priority-prefetch", type: "assess", page: page, action: action, purpose: "intent"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let wasCancelled = await priorityEvents.contains("manual-cancelled")
        assert(!wasCancelled && ModelFixture.calls == callsBeforePrefetch)
        await priorityEvents.add("release")
        let manualResult = try await manualWork.value
        let automaticResult = await automatic.value
        assert(manualResult == "manual-complete" && automaticResult.ok)

        // Explicit text/vision checks and legacy held actions can both cancel
        // a background job instead of waiting behind ambient inference.
        for priority in [LocalInferenceScheduler.Priority.interactive, .browserAction] {
            let scheduler = LocalInferenceScheduler()
            let events = Events()
            let background = Task {
                try await scheduler.run(priority: .background) {
                    await events.add("background")
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "background"
                }
            }
            while !(await events.contains("background")) { await Task.yield() }
            let start = Date()
            let foreground = try await scheduler.run(priority: priority) { "action" }
            assert(foreground == "action" && Date().timeIntervalSince(start) < 1)
            do { _ = try await background.value; assertionFailure("Background inference was not cancelled") }
            catch is CancellationError {} catch { assertionFailure("Unexpected cancellation: \(error)") }
        }
        print("PASS: browser risk routing, native action decisions, one-use terminal choices, failure/notice receipts, hidden rejection, expiry, privacy and action-priority cancellation")
    }
}
