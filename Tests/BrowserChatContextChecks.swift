import Foundation

@main struct BrowserChatContextChecks {
    @MainActor static func main() async throws {
        let page = BrowserRequest.Page(url:"https://person:password@example.test/article?token=private#secret",title:"Public\u{0001} article",text:"Visible public text\u{0002}")
        func poll(_ broker: BrowserChatContextBroker) -> BrowserResponse {
            broker.handle(BrowserRequest(id:UUID().uuidString,type:"chat-context-poll"))!
        }
        func pending(_ broker: BrowserChatContextBroker) async throws -> BrowserResponse {
            for _ in 0..<100 {
                let response = poll(broker)
                if response.contextRequestID != nil { return response }
                try await Task.sleep(nanoseconds:1_000_000)
            }
            fatalError("An explicit context request never reached the mailbox")
        }
        func result(_ id: String, page supplied: BrowserRequest.Page? = nil) -> BrowserRequest {
            BrowserRequest(id:UUID().uuidString,type:"chat-context-result",page:supplied ?? page,
                contextRequestID:id,tabID:7,windowID:2,documentID:"opaque-document-nonce")
        }
        func expect(_ task: Task<BrowserChatContext,Error>, _ expected: BrowserChatContextBroker.ContextError) async {
            do { _ = try await task.value; assertionFailure("An unavailable context was returned") }
            catch let error as BrowserChatContextBroker.ContextError {
                assert(String(describing:error) == String(describing:expected))
            } catch { assertionFailure("Unexpected context error: \(error)") }
        }

        var clock = Date(timeIntervalSince1970:1_793_300_000)
        let broker = BrowserChatContextBroker(now:{ clock })
        assert(poll(broker).contextRequestID == nil)
        assert(broker.handle(BrowserRequest(id:"ordinary-status",type:"status")) == nil)
        let asked = Task { @MainActor in try await broker.requestContext() }
        let request = try await pending(broker), token = request.contextRequestID!
        assert(UUID(uuidString:token) != nil && request.contextExpiresAt == Int64((clock.timeIntervalSince1970+6)*1_000))
        assert(poll(broker).contextRequestID == token,"Polling cannot rotate or consume an explicit question's token.")
        let wire = try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
        for forbidden in ["page","url","title","text","screenshot","tab_id","window_id","document_id","context_error"] {
            assert(wire[forbidden] == nil,"The pull mailbox must contain no browser evidence.")
        }
        let wrongToken = broker.handle(result(UUID().uuidString))!
        assert(!wrongToken.ok && poll(broker).contextRequestID == token)
        let reply = broker.handle(result(token))!
        assert(reply.ok && reply.contextRequestID == nil && reply.lastAssessment == nil && reply.completedAssessments == nil)
        let context = try await asked.value
        assert(context.page.url == "https://example.test/article")
        assert(context.page.title == "Public article" && context.page.text == "Visible public text")
        assert(context.tabID == 7 && context.windowID == 2 && context.documentID == "opaque-document-nonce")
        assert(poll(broker).contextRequestID == nil && !broker.handle(result(token))!.ok,
            "Delivery removes the pending request and rejects replay.")

        // Measured document content and exact-assessment leases survive the
        // same validated context mailbox. Toolbar/section text is not proof
        // that an image-only message was understood by the model.
        let quality = BrowserContentEvidence(primaryTextCharacters: 12, visibleTextCharacters: 600,
            substantialVisuals: 1, requiresVisual: true, truncated: false, visualRevision: 2)
        let visualPage = BrowserRequest.Page(url: "https://example.test/message", title: "Message",
            text: "Visible link destinations: Visible forms: public toolbar labels", evidence: quality)
        let checkedAt = Int64(clock.timeIntervalSince1970 * 1_000)
        let proof = BrowserCoverageProof(state: "completed", assessmentID: "assessment-opaque",
            checkedAt: checkedAt, expiresAt: checkedAt + 300_000)
        let measured = Task { @MainActor in try await broker.requestContext() }
        let measuredID = try await pending(broker).contextRequestID!
        let measuredReply = BrowserRequest(id: UUID().uuidString, type: "chat-context-result", page: visualPage,
            contextRequestID: measuredID, tabID: 7, windowID: 2, documentID: "document-b", browserCoverage: proof)
        assert(broker.handle(measuredReply)!.ok)
        let measuredContext = try await measured.value
        assert(measuredContext.page.evidence == quality && measuredContext.coverage == proof)
        assert(quality.needsVisualContext && proof.isFresh(at: clock))
        let pendingProof = BrowserCoverageProof(state: "checking", assessmentID: "pending-opaque",
            checkedAt: checkedAt, expiresAt: checkedAt + 35_000)
        let stillSame = BrowserChatContext(page: visualPage, tabID: 7, windowID: 2, documentID: "document-b", coverage: pendingProof)
        assert(stillSame.matchesContent(of: measuredContext) && stillSame.monitoringIdentity == measuredContext.monitoringIdentity,
            "Completing a model operation does not change the browser document identity.")
        func push(tab: Int = 7, window: Int = 2, document: String? = "document-b",
            phase: String = "completed", assessment: String? = "assessment-opaque",
            expires: Int64 = checkedAt + 8_000) -> BrowserPredictionUpdate {
            BrowserPredictionUpdate(sourceID: UUID().uuidString, title: visualPage.title, tabID: tab,
                windowID: window, documentID: document, phase: phase, assessmentID: assessment, expiresAt: expires)
        }
        assert(measuredContext.prefersPredictionPush(push(), resultCompletedAt: nil, now: clock),
            "The fresh current-page receipt identifies the same native assessment.")
        for differentSource in [push(tab: 8), push(window: 3), push(document: "document-c"), push(document: nil)] {
            assert(!measuredContext.prefersPredictionPush(differentSource, resultCompletedAt: clock.addingTimeInterval(1), now: clock),
                "Same-title tabs, windows and replacement documents must not inherit an old prediction.")
        }
        let changedRoute = BrowserChatContext(page: .init(url: visualPage.url, title: visualPage.title,
            text: "A different message selected through a same-URL hash route."), tabID: 7, windowID: 2, documentID: "document-b")
        assert(!changedRoute.prefersPredictionPush(push(), resultCompletedAt: clock.addingTimeInterval(1), now: clock),
            "A fresh SPA snapshot without matching coverage clears an older push even before its lease expires.")
        let intent = push(assessment: "newer-native-intent")
        assert(measuredContext.prefersPredictionPush(intent, resultCompletedAt: clock.addingTimeInterval(0.1), now: clock))
        assert(!measuredContext.prefersPredictionPush(intent, resultCompletedAt: clock, now: clock))
        assert(!measuredContext.prefersPredictionPush(intent, resultCompletedAt: clock.addingTimeInterval(-0.1), now: clock))
        assert(!measuredContext.prefersPredictionPush(intent, resultCompletedAt: nil, now: clock))
        assert(!measuredContext.prefersPredictionPush(push(phase: "waiting", assessment: nil),
            resultCompletedAt: clock.addingTimeInterval(1), now: clock))
        assert(!stillSame.prefersPredictionPush(intent, resultCompletedAt: clock.addingTimeInterval(1), now: clock),
            "A checking page cannot establish that an unrelated completed intent describes its fresh content.")
        assert(stillSame.prefersPredictionPush(push(phase: "checking", assessment: pendingProof.assessmentID),
            resultCompletedAt: nil, now: clock))
        assert(!measuredContext.prefersPredictionPush(push(expires: checkedAt), resultCompletedAt: nil, now: clock))
        assert(!measuredContext.prefersPredictionPush(push(expires: checkedAt + 308_000), resultCompletedAt: nil,
            now: clock.addingTimeInterval(300)), "A fresh push cannot revive an expired page assessment.")
        let predictionSourceID = UUID().uuidString
        let attributed = Task { @MainActor in try await broker.requestContext() }
        let attributedID = try await pending(broker).contextRequestID!
        assert(broker.handle(BrowserRequest(id: UUID().uuidString, type: "chat-context-result", page: visualPage,
            contextRequestID: attributedID, tabID: 7, windowID: 2, documentID: "document-b",
            predictionSourceID: predictionSourceID))!.ok)
        let attributedContext = try await attributed.value
        assert(attributedContext.predictionSourceID == predictionSourceID && attributedContext.coverage == nil)
        let aligned = BrowserPredictionUpdate(sourceID: predictionSourceID, title: visualPage.title, tabID: 7,
            windowID: 2, documentID: "document-b", phase: "completed", assessmentID: "image-assessment", expiresAt: checkedAt + 8000)
        assert(attributedContext.prefersPredictionPush(aligned, resultCompletedAt: nil, now: clock),
            "An exact worker-provided page epoch aligns visual or unknown predictions without a text-coverage receipt.")
        assert(!attributedContext.prefersPredictionPush(push(), resultCompletedAt: clock.addingTimeInterval(1), now: clock),
            "A different source epoch cannot win by reusing a title, document or newer timestamp.")
        let routedAgain = BrowserChatContext(page: visualPage, tabID: 7, windowID: 2, documentID: "document-b",
            predictionSourceID: UUID().uuidString)
        assert(!routedAgain.matchesContent(of: attributedContext) && routedAgain.monitoringIdentity != attributedContext.monitoringIdentity)
        assert(!routedAgain.prefersPredictionPush(aligned, resultCompletedAt: clock.addingTimeInterval(1), now: clock),
            "An identical-body hash route still ends the previous source epoch.")
        let changedImage = BrowserContentEvidence(primaryTextCharacters: 12, visibleTextCharacters: 600,
            substantialVisuals: 1, requiresVisual: true, truncated: false, visualRevision: 3)
        let revisedPage = BrowserRequest.Page(url: visualPage.url, title: visualPage.title, text: visualPage.text, evidence: changedImage)
        for different in [
            BrowserChatContext(page: visualPage, tabID: 8, windowID: 2, documentID: "document-b"),
            BrowserChatContext(page: visualPage, tabID: 7, windowID: 3, documentID: "document-b"),
            BrowserChatContext(page: visualPage, tabID: 7, windowID: 2, documentID: "document-c"),
            BrowserChatContext(page: revisedPage, tabID: 7, windowID: 2, documentID: "document-b")
        ] { assert(!different.matchesContent(of: measuredContext) && different.monitoringIdentity != measuredContext.monitoringIdentity) }
        let headersOnly = BrowserContentEvidence(primaryTextCharacters: 0, visibleTextCharacters: 0,
            substantialVisuals: 0, requiresVisual: false, truncated: false)
        assert(headersOnly.needsVisualContext, "Synthetic snapshot headers cannot qualify as semantic content.")
        let article = BrowserContentEvidence(primaryTextCharacters: 900, visibleTextCharacters: 900,
            substantialVisuals: 1, requiresVisual: false, truncated: false)
        assert(!article.needsVisualContext, "A measured readable article with a small banner remains text-first.")
        for invalidQuality in [
            BrowserContentEvidence(primaryTextCharacters: -1, visibleTextCharacters: 0, substantialVisuals: 0, requiresVisual: false, truncated: false),
            BrowserContentEvidence(primaryTextCharacters: 1, visibleTextCharacters: 0, substantialVisuals: 0, requiresVisual: false, truncated: false),
            BrowserContentEvidence(primaryTextCharacters: 8_001, visibleTextCharacters: 8_001, substantialVisuals: 0, requiresVisual: false, truncated: false),
            BrowserContentEvidence(primaryTextCharacters: 1, visibleTextCharacters: 1, substantialVisuals: 65, requiresVisual: false, truncated: false),
            BrowserContentEvidence(primaryTextCharacters: 1, visibleTextCharacters: 1, substantialVisuals: 1, requiresVisual: true, truncated: false, visualRevision: -1)
        ] { do { _ = try invalidQuality.validated(); fatalError("Invalid content-quality metadata accepted") } catch {} }
        assert(!proof.isFresh(at: clock.addingTimeInterval(300)))
        assert(!pendingProof.isFresh(at: clock.addingTimeInterval(35)))
        assert(!proof.isFresh(at: clock.addingTimeInterval(-2)))
        for invalidProof in [
            BrowserCoverageProof(state: "unknown", assessmentID: "opaque", checkedAt: checkedAt, expiresAt: checkedAt + 1_000),
            BrowserCoverageProof(state: "completed", assessmentID: "", checkedAt: checkedAt, expiresAt: checkedAt + 1_000),
            BrowserCoverageProof(state: "completed", assessmentID: "opaque", checkedAt: checkedAt, expiresAt: checkedAt + 300_001),
            BrowserCoverageProof(state: "checking", assessmentID: "opaque", checkedAt: checkedAt, expiresAt: checkedAt + 35_001)
        ] { do { _ = try invalidProof.validated(); fatalError("Unbounded or invalid coverage lease accepted") } catch {} }

        let unavailable = Task { @MainActor in try await broker.requestContext() }
        let unavailableToken = try await pending(broker).contextRequestID!
        let unavailableReply = broker.handle(BrowserRequest(id:"unavailable",type:"chat-context-result",
            contextRequestID:unavailableToken,contextError:"This page is unsupported."))!
        assert(unavailableReply.ok)
        await expect(unavailable,.unavailable)
        assert(poll(broker).contextRequestID == nil)

        let malformed = Task { @MainActor in try await broker.requestContext() }
        let malformedToken = try await pending(broker).contextRequestID!
        let malformedReply = broker.handle(BrowserRequest(id:"incomplete",type:"chat-context-result",contextRequestID:malformedToken))!
        assert(!malformedReply.ok)
        await expect(malformed,.invalidContext)
        assert(poll(broker).contextRequestID == nil)

        let expired = Task { @MainActor in try await broker.requestContext() }
        let expiredToken = try await pending(broker).contextRequestID!
        clock = clock.addingTimeInterval(6.001)
        assert(!broker.handle(result(expiredToken))!.ok)
        await expect(expired,.timedOut)
        assert(poll(broker).contextRequestID == nil)

        let timerBroker = BrowserChatContextBroker(timeout:0.025)
        let timed = Task { @MainActor in try await timerBroker.requestContext() }
        _ = try await pending(timerBroker)
        await expect(timed,.timedOut)
        assert(poll(timerBroker).contextRequestID == nil,"A real timer expires a request even if Chrome stops polling.")

        let cancelled = Task { @MainActor in try await broker.requestContext() }
        let cancelledToken = try await pending(broker).contextRequestID!
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Cancelled question received context") }
        catch is CancellationError {} catch { assertionFailure("Unexpected cancellation: \(error)") }
        assert(poll(broker).contextRequestID == nil && !broker.handle(result(cancelledToken))!.ok)

        // Cancellation and a source reply can arrive in the same actor turn.
        // Even if reply delivery wins the mailbox race, the cancelled caller
        // must not continue to a model operation with that stale question.
        let raced = Task { @MainActor in try await broker.requestContext() }
        let racedToken = try await pending(broker).contextRequestID!
        raced.cancel(); _ = broker.handle(result(racedToken))
        do { _ = try await raced.value; assertionFailure("Cancellation lost to context delivery") }
        catch is CancellationError {} catch { assertionFailure("Unexpected delivery race: \(error)") }
        assert(poll(broker).contextRequestID == nil)

        var queued: [Task<BrowserChatContext,Error>] = []
        for _ in 0..<4 {
            queued.append(Task { @MainActor in try await broker.requestContext() })
            try await Task.sleep(nanoseconds:2_000_000)
        }
        let full = Task { @MainActor in try await broker.requestContext() }
        await expect(full,.busy)
        var served = Set<String>()
        for waiting in queued {
            let head = poll(broker).contextRequestID!
            assert(served.insert(head).inserted)
            assert(broker.handle(result(head))!.ok)
            _ = try await waiting.value
        }
        assert(poll(broker).contextRequestID == nil,"The bounded FIFO retains no consumed browser context.")

        _ = try BrowserRequest(id:"poll",type:"chat-context-poll").validated()
        _ = try result(UUID().uuidString).validated()
        let validError = BrowserRequest(id:"error",type:"chat-context-result",contextRequestID:UUID().uuidString,contextError:"Unavailable")
        _ = try validError.validated()
        let id = UUID().uuidString
        let invalid = [
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,tabID:7,windowID:2,documentID:"doc",predictionSourceID:"malformed-source"),
            BrowserRequest(id:"x",type:"chat-context-result",contextRequestID:id,contextError:"Unavailable",predictionSourceID:UUID().uuidString),
            BrowserRequest(id:"x",type:"status",predictionSourceID:UUID().uuidString),
            BrowserRequest(id:"x",type:"chat-context-poll",page:page),
            BrowserRequest(id:"x",type:"chat-context-poll",contextRequestID:id),
            BrowserRequest(id:"x",type:"chat-context-poll",mode:"vision"),
            BrowserRequest(id:"x",type:"chat-context-poll",protectionEnabled:true),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:"not-a-uuid",tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,tabID:0,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,tabID:7,windowID:-1,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,tabID:7,windowID:2,documentID:String(repeating:"a",count:257)),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,tabID:7,windowID:2,documentID:"doc\n"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,contextRequestID:id,contextError:"Unavailable"),
            BrowserRequest(id:"x",type:"chat-context-result",contextRequestID:id,contextError:"",tabID:nil),
            BrowserRequest(id:"x",type:"chat-context-result",contextRequestID:id,contextError:String(repeating:"a",count:257)),
            BrowserRequest(id:"x",type:"chat-context-result",contextRequestID:id,contextError:"Unavailable",tabID:7),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,action:.init(kind:"page",url:nil,label:nil,method:nil,sensitive:nil),contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,screenshot:"private-image",contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,assessmentID:"one",contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,reason:"checking",contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,purpose:"proactive",contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            BrowserRequest(id:"x",type:"chat-context-result",page:page,protectionEnabled:false,contextRequestID:id,tabID:7,windowID:2,documentID:"doc"),
            result(id,page:.init(url:"file:///private",title:"",text:"")),
            result(id,page:.init(url:"https://example.test/",title:"",text:String(repeating:"a",count:8001))),
            BrowserRequest(id:"x",type:"status",contextRequestID:id),
            BrowserRequest(id:"x",type:"assess",page:page,tabID:7),
            BrowserRequest(id:"x",type:"protection-state",protectionEnabled:true,contextError:"Unavailable")
        ]
        for request in invalid {
            do { _ = try request.validated(); fatalError("Invalid chat context wire request accepted") } catch {}
        }
        let encoded = try JSONEncoder().encode(result(id))
        let decoded = try JSONDecoder().decode(BrowserRequest.self,from:encoded)
        assert(decoded.contextRequestID == id && decoded.tabID == 7 && decoded.windowID == 2)
        let decodedPoll = try JSONDecoder().decode(BrowserResponse.self,from:JSONEncoder().encode(request))
        assert(decodedPoll.contextRequestID == token && decodedPoll.contextExpiresAt != nil)
        print("PASS: explicit browser context mailbox, redacted bounded source metadata, current token/deadline correlation, one-use delivery, cancellation races, real timeout, bounded FIFO and evidence-free polling")
    }
}
