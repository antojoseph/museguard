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

/// Hold actual URLSession requests so cancellation tests exercise the HTTP
/// task and shared scheduler rather than only cancelling a synthetic delay.
private final class HeldModelFixture: URLProtocol {
    private static let lock = NSLock()
    private static var loading: [HeldModelFixture] = []
    private static var startedCount = 0
    private static var stoppedCount = 0
    static var counts: (started: Int, stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (startedCount, stoppedCount)
    }
    static func finish() {
        lock.lock(); let requests = loading; loading.removeAll(); lock.unlock()
        for request in requests {
            let content = #"{"risk_level":"high","summary":"Synthetic sensitive destination.","guidance":"Stay here.","categories":["credential_theft"]}"#
            let body: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
            let response = HTTPURLResponse(url: request.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: try! JSONSerialization.data(withJSONObject: body))
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.startedCount += 1; Self.loading.append(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stoppedCount += 1; Self.loading.removeAll { $0 === self }
    }
}

@main struct BrowserAssessmentChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFixture.self]
        let inferenceScheduler = LocalInferenceScheduler()
        let analyzer = LocalRiskAnalyzer(session: URLSession(configuration: config), scheduler: inferenceScheduler)
        var presentations = 0
        var presented: [BrowserRequest] = []
        var protectionChanges: [Bool] = []
        var testNow = Date()
        let coordinator = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { true }, now: { testNow },
            onProtectionChanged: { protectionChanges.append($0) },
            onPresent: { request,_,snapshot in
                presentations += 1; presented.append(request)
                assert(snapshot.text.isEmpty)
                return true
            })
        let page = BrowserRequest.Page(url: "https://account-check.example.test/login?token=private#secret", title: "Account check", text: "Enter a password and one-time code to stop deletion.")
        let action = BrowserRequest.Action(kind: "submit", url: "https://account-check.example.test/post", label: "Verify", method: "POST", sensitive: true)
        func present(_ owner: BrowserAssessmentCoordinator, _ id: String) async -> BrowserResponse {
            await owner.handle(BrowserRequest(id: UUID().uuidString, type: "present", assessmentID: id))
        }
        let status = await coordinator.handle(BrowserRequest(id: "status", type: "status"))
        assert(status.ok && status.modelReady == true && ModelFixture.calls == 0)
        assert(status.lastAssessment == nil && status.completedAssessments == 0)
        for enabled in [true,true,false] {
            let heartbeat = await coordinator.handle(BrowserRequest(id:"protection",type:"protection-state",protectionEnabled:enabled))
            assert(heartbeat.ok && heartbeat.riskLevel == "unknown" && heartbeat.decision == "review")
            assert(heartbeat.lastAssessment == nil && heartbeat.completedAssessments == nil)
        }
        assert(protectionChanges == [true,true,false], "Each heartbeat renews the awake lease.")
        assert(ModelFixture.calls == 0 && coordinator.completedCount == 0 && presentations == 0)
        for invalidState in [BrowserRequest(id:"missing-protection",type:"protection-state"),
                             BrowserRequest(id:"evidence-protection",type:"protection-state",page:page,protectionEnabled:true),
                             BrowserRequest(id:"wrong-protection",type:"status",protectionEnabled:true)] {
            let rejected = await coordinator.handle(invalidState)
            assert(!rejected.ok)
        }
        assert(protectionChanges == [true,true,false] && ModelFixture.calls == 0)
        var expectedCompletions = 0
        for (risk, expected) in [("high","block"),("medium","review"),("unknown","review"),("safe","allow"),("low","allow")] {
            ModelFixture.risk = risk
            let id = UUID().uuidString
            let result = await coordinator.handle(BrowserRequest(id:id,type:"assess",page:page,action:action,purpose:"proactive"))
            assert(result.ok && result.decision == expected && result.riskLevel == risk)
            assert(result.lastAssessment == nil && result.completedAssessments == nil)
            expectedCompletions += 1
            let completed = await coordinator.handle(BrowserRequest(id:"completed-status",type:"status"))
            assert(completed.completedAssessments == expectedCompletions)
            assert(completed.lastAssessment?.id == id && completed.lastAssessment?.kind == "submit")
            assert(completed.lastAssessment?.riskLevel == risk && completed.lastAssessment?.ok == true)
            assert(completed.lastAssessment?.completedAt == Int64(testNow.timeIntervalSince1970*1_000))
            let manualRoute = await present(coordinator,id)
            assert(!manualRoute.ok, "Automatic receipts cannot use the manual page-presentation route.")
            let displayID = UUID().uuidString
            let shown = await coordinator.handle(BrowserRequest(id:displayID,type:"present-block",assessmentID:id))
            if risk == "high" {
                assert(shown.ok && shown.decision == "block" && presentations == 1)
                assert(presented.last?.id == displayID && presented.last?.page?.text == "" && presented.last?.screenshot == nil)
                let replay = await coordinator.handle(BrowserRequest(id:displayID,type:"present-block",assessmentID:id))
                assert(!replay.ok && presentations == 1, "A display ID cannot be replayed.")
            } else {
                assert(!shown.ok && presentations == 0, "Only confirmed high findings can use automatic presentation.")
            }
            let afterPresentation = await coordinator.handle(BrowserRequest(id:"after-presentation",type:"status"))
            assert(afterPresentation.lastAssessment?.id == id && afterPresentation.completedAssessments == expectedCompletions)
            presentations = 0
        }
        assert(ModelFixture.directCalls == 5, "Browser text checks use bounded direct-answer mode.")
        let beforeHeartbeat = await coordinator.handle(BrowserRequest(id:"before-heartbeat",type:"status"))
        let callsBeforeHeartbeat = ModelFixture.calls
        testNow = testNow.addingTimeInterval(1)
        _ = await coordinator.handle(BrowserRequest(id:"renew-protection",type:"protection-state",protectionEnabled:true))
        _ = await coordinator.handle(BrowserRequest(id:"pause-protection",type:"protection-state",protectionEnabled:false))
        let afterHeartbeat = await coordinator.handle(BrowserRequest(id:"after-heartbeat",type:"status"))
        assert(protectionChanges == [true,true,false,true,false])
        assert(afterHeartbeat.lastAssessment?.id == beforeHeartbeat.lastAssessment?.id &&
               afterHeartbeat.lastAssessment?.completedAt == beforeHeartbeat.lastAssessment?.completedAt &&
               afterHeartbeat.completedAssessments == beforeHeartbeat.completedAssessments)
        assert(ModelFixture.calls == callsBeforeHeartbeat && presentations == 0)

        // Manual popup checks retain their page-only presentation path.
        ModelFixture.risk = "medium"
        let manual = await coordinator.handle(BrowserRequest(id:"manual-page",type:"assess",page:page))
        assert(manual.ok && manual.decision == "review")
        let manualShown = await present(coordinator,"manual-page")
        assert(manualShown.ok && presented.last?.id == "manual-page")
        let manualReplay = await present(coordinator,"manual-page")
        assert(!manualReplay.ok)
        let cleaned = try BrowserRequest(id:"clean",type:"assess",page:page).validated()
        let evidence = BrowserAssessmentCoordinator.snapshot(for:cleaned,page:cleaned.page!)
        assert(!evidence.text.contains("token=private") && !evidence.text.contains("#secret"))
        assert(evidence.appName == "Google Chrome")

        // A fresh cached high finding can produce a new warning, but no grant
        // or acknowledgment protocol is exposed to the browser.
        ModelFixture.risk = "high"
        let cachedHigh = await coordinator.handle(BrowserRequest(id:"cached-high",type:"assess",page:page,action:action,purpose:"proactive"))
        assert(cachedHigh.ok && cachedHigh.riskLevel == "high")
        let reusedFindingID = await coordinator.handle(BrowserRequest(id:"cached-high",type:"present-block",assessmentID:"cached-high"))
        assert(!reusedFindingID.ok)
        for displayID in ["high-display-one","high-display-two"] {
            let shown = await coordinator.handle(BrowserRequest(id:displayID,type:"present-block",assessmentID:"cached-high"))
            assert(shown.ok && shown.decision == "block" && presented.last?.id == displayID)
            let cancelled = await coordinator.handle(BrowserRequest(id:UUID().uuidString,type:"cancel",assessmentID:displayID))
            assert(cancelled.ok && cancelled.riskLevel == "unknown" && cancelled.decision == "review")
            let replay = await coordinator.handle(BrowserRequest(id:displayID,type:"present-block",assessmentID:"cached-high"))
            assert(!replay.ok, "Browser cleanup cannot free a visible warning's presentation ID for reuse.")
        }
        _ = await coordinator.handle(BrowserRequest(id:"revoke-high",type:"cancel",assessmentID:"cached-high"))
        let revoked = await coordinator.handle(BrowserRequest(id:"revoked-display",type:"present-block",assessmentID:"cached-high"))
        assert(!revoked.ok, "Cancelling original evidence revokes its cached finding, without touching native warning state.")

        let successesBeforeFailure = coordinator.completedCount
        ModelFixture.malformed = true
        let invalid = await coordinator.handle(BrowserRequest(id:"malformed",type:"assess",page:page))
        assert(!invalid.ok && invalid.decision == "review" && invalid.riskLevel == "unknown")
        let failureStatus = await coordinator.handle(BrowserRequest(id:"failure-status",type:"status"))
        assert(failureStatus.lastAssessment?.id == "malformed" && failureStatus.lastAssessment?.kind == "page")
        assert(failureStatus.lastAssessment?.ok == false && failureStatus.completedAssessments == successesBeforeFailure)
        let malformedShown = await present(coordinator,"malformed")
        assert(!malformedShown.ok && presented.last?.id == "malformed", "An explicit failed popup check remains presentable by Muse.")
        ModelFixture.malformed = false
        let unavailable = BrowserAssessmentCoordinator(analyzer:analyzer,modelReady:{false})
        let stopped = await unavailable.handle(BrowserRequest(id:"stopped",type:"assess",page:page))
        assert(!stopped.ok && stopped.decision == "review")
        let stoppedStatus = await unavailable.handle(BrowserRequest(id:"stopped-status",type:"status"))
        assert(stoppedStatus.modelReady == false && stoppedStatus.lastAssessment?.ok == false)
        let denied = BrowserAssessmentCoordinator(analyzer:analyzer,modelReady:{true},isDenied:{_ in true})
        let skipped = await denied.handle(BrowserRequest(id:"denied",type:"assess",page:page,purpose:"proactive"))
        assert(!skipped.ok && skipped.decision == "review")
        assert(!skipped.guidance.isEmpty)

        let callsBeforeNotices = ModelFixture.calls
        for reason in ["changed","unavailable"] {
            let id = "notice-"+reason
            let result = await coordinator.handle(BrowserRequest(id:id,type:"notice",page:page,
                action:.init(kind:"page",url:page.url,label:nil,method:"GET",sensitive:nil),reason:reason))
            assert(!result.ok && result.decision == "review" && result.riskLevel == "unknown")
            _ = await present(coordinator,id)
            assert(presented.last?.reason == reason)
        }
        assert(ModelFixture.calls == callsBeforeNotices, "Connection notices never run inference.")
        for retired in [BrowserRequest(id:"retired-decision",type:"decision",assessmentID:"manual-page"),
                        BrowserRequest(id:"retired-finish",type:"finish-checking",assessmentID:"manual-page"),
                        BrowserRequest(id:"retired-checking",type:"notice",page:page,reason:"checking"),
                        BrowserRequest(id:"retired-unsupported",type:"notice",page:page,reason:"unsupported"),
                        BrowserRequest(id:"retired-open",type:"notice",page:page,reason:"open_failed"),
                        BrowserRequest(id:"retired-held",type:"assess",page:page,action:action),
                        BrowserRequest(id:"retired-notice-action",type:"notice",page:page,action:action,reason:"unavailable")] {
            let result = await coordinator.handle(retired)
            assert(!result.ok)
        }
        assert(ModelFixture.calls == callsBeforeNotices)
        let latestBeforeExpiry = await coordinator.handle(BrowserRequest(id:"latest-before-expiry",type:"status"))
        assert(latestBeforeExpiry.lastAssessment?.id == "malformed", "Notices, rejected protocols and presentation must not replace assessment diagnostics.")
        _ = await coordinator.handle(BrowserRequest(id:"receipt-expiry",type:"notice",page:page,reason:"unavailable"))
        testNow = testNow.addingTimeInterval(16)
        let expiredReceipt = await present(coordinator,"receipt-expiry")
        assert(!expiredReceipt.ok)
        let hidden = BrowserAssessmentCoordinator(analyzer:analyzer,modelReady:{true},onPresent:{_,_,_ in false})
        _ = await hidden.handle(BrowserRequest(id:"hidden",type:"assess",page:page))
        let hiddenPresentation = await present(hidden,"hidden")
        assert(!hiddenPresentation.ok)
        _ = await coordinator.handle(BrowserRequest(id:"high-expiry",type:"assess",page:page,action:action,purpose:"proactive"))
        testNow = testNow.addingTimeInterval(61)
        let expiredHigh = await coordinator.handle(BrowserRequest(id:"expired-high",type:"present-block",assessmentID:"high-expiry"))
        assert(!expiredHigh.ok)
        _ = await coordinator.handle(BrowserRequest(id:"cancel-before-present",type:"notice",page:page,reason:"unavailable"))
        _ = await coordinator.handle(BrowserRequest(id:"cancel-early",type:"cancel",assessmentID:"cancel-before-present"))
        let cancelledPresentation = await present(coordinator,"cancel-before-present")
        assert(!cancelledPresentation.ok)

        // Automatic destination prefetch must not interrupt an explicit user
        // check, even when its descriptor happens to be a form submission.
        let priorityEvents = Events()
        let manualWork = Task {
            do {
                return try await inferenceScheduler.run(priority: .interactive) {
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

        // Sensitive intent interrupts a routine scan, while ordinary hover
        // intent stays background and ongoing interactive work keeps its slot.
        let ordinaryAction = BrowserRequest.Action(kind:"submit",url:page.url,label:"Search",method:"GET",sensitive:false)
        let linkAction = BrowserRequest.Action(kind:"link",url:page.url,label:"Read",method:"GET",sensitive:true)
        for request in [BrowserRequest(id:"hover-link",type:"assess",page:page,action:linkAction,purpose:"intent"),
                        BrowserRequest(id:"ordinary-submit",type:"assess",page:page,action:ordinaryAction,purpose:"intent"),
                        BrowserRequest(id:"automatic-sensitive",type:"assess",page:page,action:action,purpose:"proactive")] {
            assert(BrowserAssessmentCoordinator.priority(for:request) == .background)
        }
        assert(BrowserAssessmentCoordinator.priority(for:BrowserRequest(id:"manual",type:"assess",page:page)) == .interactive)
        let routineEvents = Events()
        let routine = Task {
            try await inferenceScheduler.run(priority:.background) {
                await routineEvents.add("started")
                try await Task.sleep(nanoseconds:5_000_000_000)
                return "obsolete scan"
            }
        }
        while !(await routineEvents.contains("started")) { await Task.yield() }
        let sensitiveStart = Date()
        let sensitiveIntent = await coordinator.handle(BrowserRequest(id:"sensitive-intent",type:"assess",page:page,action:action,purpose:"intent"))
        assert(sensitiveIntent.ok && Date().timeIntervalSince(sensitiveStart) < 1,
            "Meaningful sensitive intent must not wait behind a routine scan.")
        do { _ = try await routine.value; assertionFailure("Sensitive intent did not interrupt routine work") }
        catch is CancellationError {} catch { assertionFailure("Unexpected routine cancellation: \(error)") }

        let heldConfig = URLSessionConfiguration.ephemeral
        heldConfig.protocolClasses = [HeldModelFixture.self]
        let heldAnalyzer = LocalRiskAnalyzer(session:URLSession(configuration:heldConfig),scheduler:inferenceScheduler)
        let cancelling = BrowserAssessmentCoordinator(analyzer:heldAnalyzer,modelReady:{true})
        func waitForHTTP(_ count: Int) async throws {
            for _ in 0..<1000 {
                if HeldModelFixture.counts.started >= count { return }
                try await Task.sleep(nanoseconds:1_000_000)
            }
            fatalError("The held model request never started")
        }
        func assertNoCancelledReceipt(_ id: String) async {
            let stalePresent = await present(cancelling,id)
            let staleBlock = await cancelling.handle(BrowserRequest(id:UUID().uuidString,type:"present-block",assessmentID:id))
            assert(!stalePresent.ok && !staleBlock.ok,
                "Cancelled model work cannot create a native verdict or high finding.")
        }
        let callsBeforeEarlyCancel = HeldModelFixture.counts.started
        _ = await cancelling.handle(BrowserRequest(id:"early-cancel",type:"cancel",assessmentID:"cancel-before-dispatch"))
        let neverStarted = await cancelling.handle(BrowserRequest(id:"cancel-before-dispatch",type:"assess",page:page,purpose:"proactive"))
        assert(!neverStarted.ok && HeldModelFixture.counts.started == callsBeforeEarlyCancel,
            "A cancellation delivered before its assessment must prevent stale work from starting.")
        await assertNoCancelledReceipt("cancel-before-dispatch")
        let activeBefore = HeldModelFixture.counts
        let activeCheck = Task { @MainActor in
            await cancelling.handle(BrowserRequest(id:"obsolete-active",type:"assess",page:page,purpose:"proactive"))
        }
        try await waitForHTTP(activeBefore.started+1)
        let cancelActive = await cancelling.handle(BrowserRequest(id:"cancel-active",type:"cancel",assessmentID:"obsolete-active"))
        assert(cancelActive.ok && cancelActive.decision == "review" && cancelActive.riskLevel == "unknown")
        let activeResult = await activeCheck.value
        assert(!activeResult.ok && activeResult.riskLevel == "unknown")
        assert(HeldModelFixture.counts.stopped > activeBefore.stopped,"Cancellation reaches the actual HTTP task.")
        await assertNoCancelledReceipt("obsolete-active")
        let cancelledStatus = await cancelling.handle(BrowserRequest(id:"cancelled-status",type:"status"))
        assert(cancelledStatus.completedAssessments == 0 && cancelledStatus.lastAssessment == nil,
            "Obsolete work does not replace completed-result diagnostics.")

        // Cancellation must remove a scheduler-queued assessment before its
        // HTTP request begins, without disturbing an unrelated manual task.
        let queuedEvents = Events()
        let manualBlocker = Task {
            try await inferenceScheduler.run(priority:.interactive) {
                await queuedEvents.add("manual")
                while !(await queuedEvents.contains("release")) { try await Task.sleep(nanoseconds:1_000_000) }
                return "manual intact"
            }
        }
        while !(await queuedEvents.contains("manual")) { await Task.yield() }
        let callsBeforeQueued = HeldModelFixture.counts.started
        let queuedCheck = Task { @MainActor in
            await cancelling.handle(BrowserRequest(id:"obsolete-queued",type:"assess",page:page,purpose:"proactive"))
        }
        try await Task.sleep(nanoseconds:20_000_000)
        let cancelQueued = await cancelling.handle(BrowserRequest(id:"cancel-queued",type:"cancel",assessmentID:"obsolete-queued"))
        assert(cancelQueued.ok && cancelQueued.riskLevel == "unknown")
        let queuedResult = await queuedCheck.value
        assert(!queuedResult.ok && queuedResult.riskLevel == "unknown")
        await queuedEvents.add("release")
        let manualBlockerResult = try await manualBlocker.value
        assert(manualBlockerResult == "manual intact")
        assert(HeldModelFixture.counts.started == callsBeforeQueued,"A cancelled queued assessment must never reach HTTP.")
        await assertNoCancelledReceipt("obsolete-queued")

        // Cancelling the original caller also propagates through the owned
        // task. A subsequent fresh assessment still completes and presents.
        let callsBeforeCaller = HeldModelFixture.counts.started
        let callerCheck = Task { @MainActor in
            await cancelling.handle(BrowserRequest(id:"cancelled-caller",type:"assess",page:page,purpose:"proactive"))
        }
        try await waitForHTTP(callsBeforeCaller+1)
        callerCheck.cancel()
        let callerResult = await callerCheck.value
        assert(!callerResult.ok && callerResult.riskLevel == "unknown")
        await assertNoCancelledReceipt("cancelled-caller")
        let callsBeforeFresh = HeldModelFixture.counts.started
        let freshCheck = Task { @MainActor in
            await cancelling.handle(BrowserRequest(id:"fresh-after-cancel",type:"assess",page:page,action:action,purpose:"intent"))
        }
        try await waitForHTTP(callsBeforeFresh+1)
        HeldModelFixture.finish()
        let freshResult = await freshCheck.value
        assert(freshResult.ok && freshResult.riskLevel == "high" && cancelling.completedCount == 1)
        let freshShown = await cancelling.handle(BrowserRequest(id:"fresh-display",type:"present-block",assessmentID:"fresh-after-cancel"))
        assert(freshShown.ok && freshShown.decision == "block")
        _ = await cancelling.handle(BrowserRequest(id:"late-obsolete-cancel",type:"cancel",assessmentID:"obsolete-active"))
        let freshAgain = await cancelling.handle(BrowserRequest(id:"fresh-display-again",type:"present-block",assessmentID:"fresh-after-cancel"))
        assert(freshAgain.ok && freshAgain.decision == "block",
            "An obsolete cancellation cannot revoke a newer high finding.")
        let freshStatus = await cancelling.handle(BrowserRequest(id:"fresh-status",type:"status"))
        assert(freshStatus.lastAssessment?.id == "fresh-after-cancel" && freshStatus.completedAssessments == 1)

        print("PASS: browser risk routing, manual page presentation, fresh high findings, privacy, sensitive intent priority, HTTP/queued/caller cancellation and recovery")
    }
}
