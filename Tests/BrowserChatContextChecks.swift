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
