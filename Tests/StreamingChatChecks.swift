import Foundation
import Combine

private func event(_ object:[String:Any]) -> String {
    "data: " + String(data:try! JSONSerialization.data(withJSONObject:object),encoding:.utf8)! + "\n\n"
}
private func piece(_ text:String? = nil,reason:String? = nil,thinking:String? = nil) -> String {
    var delta:[String:Any] = [:]
    if let text { delta["content"] = text }
    if let thinking { delta["reasoning_content"] = thinking }
    var choice:[String:Any] = ["index":0,"delta":delta]
    if let reason { choice["finish_reason"] = reason }
    return event(["choices":[choice]])
}
private let done = "data: [DONE]\n\n"

private final class StreamProtocol:URLProtocol {
    static var chunks:[String] = []
    static var delay:Double = 0.04
    static var contentType = "text/event-stream"
    static var status = 200
    static var body:[String:Any] = [:]
    static var completed = false
    static var cancelled = false
    private var stopped = false
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "127.0.0.1")
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(),buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer,maxLength:buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf:buffer.prefix(count))
            }
            data = collected
        }
        Self.body = (try? JSONSerialization.jsonObject(with:data ?? Data())) as? [String:Any] ?? [:]
        Self.completed = false; Self.cancelled = false
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,
            headerFields:["Content-Type":Self.contentType])!,cacheStoragePolicy:.notAllowed)
        send(0)
    }
    private func send(_ index:Int) {
        guard !stopped else { return }
        guard index < Self.chunks.count else {
            Self.completed = true; client?.urlProtocolDidFinishLoading(self); return
        }
        client?.urlProtocol(self,didLoad:Data(Self.chunks[index].utf8))
        DispatchQueue.global().asyncAfter(deadline:.now()+Self.delay) { [weak self] in self?.send(index+1) }
    }
    override func stopLoading() {
        stopped = true
        if !Self.completed { Self.cancelled = true }
    }
}
private actor Updates {
    var values:[String] = []
    var arrivedBeforeCompletion = false
    func append(_ text:String) {
        values.append(text)
        if !StreamProtocol.completed { arrivedBeforeCompletion = true }
    }
    func snapshot() -> ([String],Bool) { (values,arrivedBeforeCompletion) }
}
private actor CallbackGate {
    private var callback:CheckedContinuation<Void,Never>?
    private var observers:[CheckedContinuation<Void,Never>] = []
    func hold() async {
        await withCheckedContinuation { continuation in
            callback = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitUntilHeld() async {
        if callback != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { callback?.resume(); callback = nil }
}

@main struct StreamingChatChecks {
    static func feed(_ stream:String) throws -> LocalChatStreamDecoder {
        var decoder = LocalChatStreamDecoder()
        for byte in stream.utf8 { _ = try decoder.append(byte:byte) }
        return decoder
    }
    static func rejects(_ stream:String) {
        do { _ = try feed(stream).completedAnswer(); assertionFailure("Accepted incomplete or invalid SSE answer") }
        catch LocalRiskAnalyzerError.interruptedChat { }
        catch { assertionFailure("Unexpected SSE error: \(error)") }
    }
    @MainActor static func main() async throws {
        let reasoning = piece(thinking:"HIDDEN_REASONING_SENTINEL")
        let usage = event(["choices":[],"usage":["prompt_tokens":120,"completion_tokens":12,"prompt_tokens_details":["cached_tokens":100]],
            "timings":["prompt_ms":15.0,"predicted_ms":300.0,"predicted_per_second":40.0]])
        let stream = ": keepalive\n\n" + reasoning + piece("Thirty") + piece(" days ☁️") + piece(reason:"stop") + usage + done
        let decoder = try feed(stream)
        let decoded = try decoder.completedAnswer()
        assert(decoded == "Thirty days ☁️")
        let timing = decoder.responseTiming(milliseconds:400,firstVisible:50)
        assert(timing.reasoningCharacters == "HIDDEN_REASONING_SENTINEL".count)
        assert(timing.visibleCharacters == "Thirty days ☁️".count)
        assert(timing.promptTokens == 120 && timing.generatedTokens == 12 && timing.cachedTokens == 100)
        assert(timing.promptMilliseconds == 15 && timing.generationMilliseconds == 300 && timing.tokensPerSecond == 40)
        assert(timing.firstVisibleMilliseconds == 50)
        let multiline = "data: {\"choices\":\ndata: [{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\r\n\r\n"+done
        let multilineAnswer = try feed(multiline).completedAnswer()
        assert(multilineAnswer == "Hi")
        for bad in [done, piece("Partial"), piece("Partial",reason:"stop"), reasoning+piece(reason:"stop")+done,
            piece("Partial",reason:"length")+done,piece("Partial",reason:"tool_calls")+done,
            "data: not-json\n\n",event(["error":["message":"PRIVATE_SERVER_ERROR"]]),
            piece("First",reason:"stop")+piece("Unexpected after stop")+done,
            event(["choices":[["index":1,"delta":["content":"Second result"]]]])+done,
            piece(String(repeating:"x",count:40000))+piece(String(repeating:"x",count:40000))+piece(reason:"stop")+done,
            String(repeating:"x",count:LocalChatStreamDecoder.maximumEventBytes+1)] { rejects(bad) }
        // Even a stream consisting only of legal comments has a total byte cap.
        rejects(String(repeating:":x\n",count:LocalChatStreamDecoder.maximumBytes/3+1))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamProtocol.self]
        let scheduler = LocalInferenceScheduler()
        let analyzer = LocalRiskAnalyzer(session:URLSession(configuration:configuration),scheduler:scheduler)
        StreamProtocol.chunks = [piece("\n"),reasoning,piece("Thirty"),piece(" days ☁️"),piece(reason:"stop"),usage,done]
        let updates = Updates()
        let answer = try await analyzer.answerQuestion("How long?",context:nil,model:LocalModelConfiguration.model,
            onVisibleAnswer: { value in await updates.append(value) })
        let (values,beforeCompletion) = await updates.snapshot()
        assert(answer == "Thirty days ☁️" && values.first == "Thirty" && values.last == answer)
        assert(beforeCompletion,"The visible callback must run before the HTTP stream finishes.")
        assert(values.allSatisfy { !$0.contains("HIDDEN_REASONING_SENTINEL") })
        assert(StreamProtocol.body["stream"] as? Bool == true)
        assert((StreamProtocol.body["stream_options"] as? [String:Bool])?["include_usage"] == true)
        assert(StreamProtocol.body["response_format"] == nil)
        assert(StreamProtocol.body["continue_final_message"] == nil && StreamProtocol.body["add_generation_prompt"] == nil)
        let measured = await scheduler.recentMetrics()
        assert(measured.last?.kind == .chat && measured.last?.outcome == "completed")
        assert(measured.last?.response?.generatedTokens == 12 && measured.last?.response?.reasoningCharacters == "HIDDEN_REASONING_SENTINEL".count)
        assert(measured.last?.response?.visibleCharacters == "Thirty days ☁️".count)
        assert(measured.last?.response?.firstVisibleMilliseconds != nil)

        StreamProtocol.chunks = [piece(" "),piece("\n"),piece("Thirty days"),piece(reason:"stop"),usage,done]
        let fastUpdates = Updates()
        let fastAnswer = try await analyzer.answerQuestion("How long?",context:nil,model:LocalModelConfiguration.model,directAnswer:true,
            onVisibleAnswer:{ value in await fastUpdates.append(value) })
        let (fastValues,_) = await fastUpdates.snapshot()
        assert(fastAnswer == "Thirty days" && fastValues.first == "Thirty days" && fastValues.allSatisfy { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty })
        let fastMessages = StreamProtocol.body["messages"] as! [[String:Any]]
        assert(fastMessages.last!["role"] as? String == "assistant" && fastMessages.last!["content"] as? String == " ")
        assert(StreamProtocol.body["continue_final_message"] as? String == "content" && StreamProtocol.body["add_generation_prompt"] as? Bool == false)
        let fastMeasured = await scheduler.recentMetrics().last!
        assert(fastMeasured.response!.firstVisibleMilliseconds! >= 60,"Whitespace-only deltas must not count as the first visible token.")
        assert(fastMeasured.response?.visibleCharacters == "Thirty days".count && fastMeasured.response?.reasoningCharacters == 0)

        StreamProtocol.chunks = [piece("A diagram"),piece(reason:"stop"),usage,done]
        let image = "data:image/png;base64,"+Data([137,80,78,71,13,10,26,10]).base64EncodedString()
        let imageContext = ScreenChatContext(snapshot:ScreenSnapshot(appName:"Canvas",windowTitle:"Diagram",text:""),
            sourceLabel:"Screenshot",screenshotDataURL:image)
        _ = try await analyzer.answerQuestion("What is shown?",context:nil,screenContext:imageContext,model:LocalModelConfiguration.model,
            directAnswer:true,onVisibleAnswer:{ _ in })
        let imageMessages = StreamProtocol.body["messages"] as! [[String:Any]]
        assert(imageMessages.last!["role"] as? String == "user")
        assert(StreamProtocol.body["continue_final_message"] == nil && StreamProtocol.body["add_generation_prompt"] == nil)
        assert(imageMessages.last!["content"] is [[String:Any]],"Streaming image chat must preserve image evidence and normal reasoning.")

        StreamProtocol.chunks = [piece("Partial"),piece(reason:"length"),done]
        do {
            _ = try await analyzer.answerQuestion("Truncated",context:nil,model:LocalModelConfiguration.model,onVisibleAnswer:{ _ in })
            assertionFailure("Truncated streamed answer was marked complete")
        } catch LocalRiskAnalyzerError.interruptedChat { }
        StreamProtocol.chunks = [piece("Partial"),piece(" rest"),piece(reason:"stop"),done]
        StreamProtocol.delay = 0.2
        do {
            _ = try await analyzer.answerQuestion("Cancel",context:nil,model:LocalModelConfiguration.model,onVisibleAnswer:{ _ in throw CancellationError() })
            assertionFailure("Callback cancellation was ignored")
        } catch is CancellationError { }
        for _ in 0..<20 where !StreamProtocol.cancelled { try await Task.sleep(nanoseconds:10_000_000) }
        assert(StreamProtocol.cancelled,"Stopping chat must cancel the underlying HTTP stream.")
        StreamProtocol.chunks = [reasoning,piece("Too late"),piece(reason:"stop"),done]
        let cancelled = Task {
            try await analyzer.answerQuestion("Cancel before visible output",context:nil,model:LocalModelConfiguration.model,onVisibleAnswer:{ _ in
                assertionFailure("A cancelled request emitted visible text")
            })
        }
        try await Task.sleep(nanoseconds:30_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Cancelled stream returned an answer") }
        catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        assert(StreamProtocol.cancelled,"Cancellation while hidden reasoning is arriving must cancel transport too.")
        StreamProtocol.delay = 0.04
        StreamProtocol.contentType = "application/json"
        do {
            _ = try await analyzer.answerQuestion("Wrong type",context:nil,model:LocalModelConfiguration.model,onVisibleAnswer:{ _ in })
            assertionFailure("Accepted non-SSE response as a stream")
        } catch LocalRiskAnalyzerError.invalidResponse { }

        let storedHidden = UserDefaults.standard.object(forKey:"museAvatarHidden")
        defer {
            if let storedHidden { UserDefaults.standard.set(storedHidden,forKey:"museAvatarHidden") }
            else { UserDefaults.standard.removeObject(forKey:"museAvatarHidden") }
        }
        let view = PetViewModel(), id = UUID()
        view.isAvatarHidden = false
        var publishedAnswers:[String] = []
        let transcriptUpdates = view.$chatMessages.sink { messages in
            if let answer = messages.first(where: { $0.id == id }) { publishedAnswers.append(answer.text) }
        }
        assert(!view.updateAssistantChat(id:id,text:"Closed chat"))
        view.openChat(); view.appendUserChat("Question"); view.beginChatResponse(id:id)
        assert(view.updateAssistantChat(id:id,text:"First"))
        assert(view.updateAssistantChat(id:id,text:"First second"))
        assert(view.chatMessages.count == 2 && view.chatMessages.last?.id == id && view.chatMessages.last?.text == "First second")
        assert(publishedAnswers.suffix(2) == ["First","First second"],"The observed transcript must publish updates to an existing row, including its final text.")
        _ = transcriptUpdates
        assert(view.isChatStreaming)
        assert(view.interruptAssistantChat(id:id,message:"This reply was interrupted. Please retry."))
        assert(view.chatMessages.last!.text.hasSuffix("Please retry.") && !view.isChatStreaming)
        view.dismissBubble()
        assert(!view.updateAssistantChat(id:id,text:"Late token") && view.chatMessages.isEmpty)
        view.openChat(); view.beginChatResponse(id:id)
        let gate = CallbackGate()
        let stale = Task.detached {
            // Model the race after the stream's cancellation check, before
            // its callback is allowed to enter the main actor.
            try Task.checkCancellation()
            await gate.hold()
            return await view.updateAssistantChat(id:id,text:"Stale token after reopening")
        }
        await gate.waitUntilHeld()
        view.dismissBubble(); view.openChat()
        await gate.release()
        let acceptedStale = try await stale.value
        assert(!acceptedStale && view.chatMessages.isEmpty,"An already-queued callback cannot repopulate a closed and reopened chat.")
        let next = UUID()
        view.beginChatResponse(id:next)
        assert(!view.updateAssistantChat(id:id,text:"Earlier request") && view.updateAssistantChat(id:next,text:"Current request"))
        view.dismissBubble(); view.openChat()
        let warningResponse = UUID()
        view.beginChatResponse(id:warningResponse); _ = view.updateAssistantChat(id:warningResponse,text:"Before warning")
        _ = view.showAcknowledgment(id:"warning",text:"Pinned warning")
        assert(!view.updateAssistantChat(id:id,text:"After warning") && view.chatMessages.isEmpty && !view.isChatStreaming)
        view.openChat(); view.beginChatResponse(id:warningResponse)
        view.isAvatarHidden = true
        assert(!view.updateAssistantChat(id:warningResponse,text:"Hidden warning reply") && !view.isChatThinking,
            "Hiding must invalidate replies even while acknowledgement prevents generic dismissal.")
        view.isAvatarHidden = false
        assert(!view.updateAssistantChat(id:warningResponse,text:"Reply after showing again"))
        print("PASS: streaming sends visible text before completion, excludes reasoning, bounds SSE, validates terminal frames, cancels transport, records aggregate timing, keeps one transcript row and rejects late hidden/dismissed updates")
    }
}
