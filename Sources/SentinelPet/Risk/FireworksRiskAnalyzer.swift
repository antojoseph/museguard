import Foundation

enum FireworksRiskAnalyzerError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int, String)
    case emptyResponse
    case malformedVerdict(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Fireworks API key in Settings before analyzing text."
        case .invalidResponse:
            return "Fireworks returned an invalid response."
        case let .requestFailed(statusCode, body):
            let details = body.isEmpty ? "No response body." : body
            return "Fireworks request failed with HTTP \(statusCode). \(details)"
        case .emptyResponse:
            return "Fireworks returned an empty analysis."
        case let .malformedVerdict(content):
            return "Fireworks returned analysis I could not parse: \(content)"
        }
    }
}

final class FireworksRiskAnalyzer {
    private let endpoint = URL(string: "https://api.fireworks.ai/inference/v1/chat/completions")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func analyze(snapshot: ScreenSnapshot, model: String, apiKey: String) async throws -> RiskVerdict {
        try await perform(
            messages: messages(for: snapshot),
            model: model,
            apiKey: apiKey
        )
    }

    func analyze(
        snapshot: ScreenSnapshot,
        screenshotDataURL: String,
        model: String,
        apiKey: String
    ) async throws -> RiskVerdict {
        try await perform(
            messages: screenshotMessages(for: snapshot, screenshotDataURL: screenshotDataURL),
            model: model,
            apiKey: apiKey
        )
    }

    func verifyManipulatedMedia(
        snapshot: ScreenSnapshot,
        screenshotDataURLs: [String],
        initialVerdict: RiskVerdict,
        model: String,
        apiKey: String
    ) async throws -> RiskVerdict {
        try await perform(
            messages: verificationMessages(
                for: snapshot,
                screenshotDataURLs: screenshotDataURLs,
                initialVerdict: initialVerdict
            ),
            model: model,
            apiKey: apiKey,
            timeoutInterval: 90
        )
    }

    private func perform(
        messages: [ChatMessage],
        model: String,
        apiKey: String,
        timeoutInterval: TimeInterval = 45
    ) async throws -> RiskVerdict {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw FireworksRiskAnalyzerError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages,
                responseFormat: ResponseFormat(type: "json_object"),
                maxTokens: 32_768,
                topP: 1,
                topK: 40,
                presencePenalty: 0,
                frequencyPenalty: 0,
                temperature: 0.6
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FireworksRiskAnalyzerError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FireworksRiskAnalyzerError.requestFailed(httpResponse.statusCode, body)
        }

        let completion = try decoder.decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FireworksRiskAnalyzerError.emptyResponse
        }

        return try decodeVerdict(from: content)
    }

    private func messages(for snapshot: ScreenSnapshot) -> [ChatMessage] {
        [
            ChatMessage(
                role: "system",
                content: [
                    .text("""
                    You are Sentinel Pet, a local desktop security assistant. Evaluate text from a focused macOS window for user-facing risk: phishing, credential theft, payment scams, remote-access scams, malware/social engineering, suspicious links, impersonation, urgency pressure, and account takeover. Return only JSON with keys risk_level, summary, guidance, categories. risk_level must be one of safe, low, medium, high. Keep summary and guidance concise.
                    """)
                ]
            ),
            ChatMessage(
                role: "user",
                content: [
                    .text("""
                    App: \(snapshot.appName)
                    Window: \(snapshot.windowTitle ?? "unknown")

                    Focused-window text:
                    \(snapshot.text)
                    """)
                ]
            )
        ]
    }

    private func screenshotMessages(
        for snapshot: ScreenSnapshot,
        screenshotDataURL: String
    ) -> [ChatMessage] {
        [
            ChatMessage(
                role: "system",
                content: [
                    .text("""
                    You are Sentinel Pet, a local desktop security assistant. Evaluate the user-requested screenshot and optional focused-window text for user-facing risk: phishing, credential theft, payment scams, remote-access scams, malware/social engineering, suspicious links, impersonation, urgency pressure, account takeover, fake login/payment screens, manipulated media, and deepfake-like cues. Return only JSON with keys risk_level, summary, guidance, categories. risk_level must be one of safe, low, medium, high. Keep summary and guidance concise.
                    """)
                ]
            ),
            ChatMessage(
                role: "user",
                content: [
                    .text("""
                    The user explicitly requested this screenshot analysis.

                    App: \(snapshot.appName)
                    Window: \(snapshot.windowTitle ?? "unknown")

                    Focused-window text, if available:
                    \(snapshot.text)
                    """),
                    .imageURL(screenshotDataURL)
                ]
            )
        ]
    }

    private func verificationMessages(
        for snapshot: ScreenSnapshot,
        screenshotDataURLs: [String],
        initialVerdict: RiskVerdict
    ) -> [ChatMessage] {
        let imageParts = screenshotDataURLs.map(ChatMessageContentPart.imageURL)

        return [
            ChatMessage(
                role: "system",
                content: [
                    .text("""
                    You are Sentinel Pet running high-detail multi-frame verification after an initial screenshot risk finding. Compare the provided frames in chronological order for manipulated media, deepfake-like cues, impersonation risk, video-call scams, fake login/payment screens, and context-driven social engineering. Be careful: do not claim definitive proof of a deepfake from screenshots alone. Return only JSON with keys risk_level, summary, guidance, categories. risk_level must be one of safe, low, medium, high. Keep summary and guidance concise, and explain whether the multi-frame evidence raises, lowers, or confirms the initial concern.
                    """)
                ]
            ),
            ChatMessage(
                role: "user",
                content: [
                    .text("""
                    The first screenshot pass returned a medium/high risk, so the app automatically captured these higher-detail verification frames after the user's screenshot-analysis action.

                    App: \(snapshot.appName)
                    Window: \(snapshot.windowTitle ?? "unknown")

                    Initial risk level: \(initialVerdict.riskLevel.rawValue)
                    Initial categories: \(initialVerdict.categories.joined(separator: ", "))
                    Initial summary: \(initialVerdict.summary)
                    Initial guidance: \(initialVerdict.guidance)

                    Focused-window text, if available:
                    \(snapshot.text)

                    Compare the frames for temporal inconsistency, face/eye/mouth artifacts, lighting or reflection mismatches, suspicious call/payment/login context, and pressure tactics.
                    """)
                ] + imageParts
            )
        ]
    }

    private func decodeVerdict(from content: String) throws -> RiskVerdict {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw FireworksRiskAnalyzerError.malformedVerdict(content)
        }

        do {
            return try decoder.decode(RiskVerdict.self, from: data)
        } catch {
            throw FireworksRiskAnalyzerError.malformedVerdict(trimmed)
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let responseFormat: ResponseFormat
    let maxTokens: Int
    let topP: Double
    let topK: Int
    let presencePenalty: Double
    let frequencyPenalty: Double
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case temperature
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: [ChatMessageContentPart]
}

private enum ChatMessageContentPart: Encodable {
    case text(String)
    case imageURL(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    enum ImageURLCodingKeys: String, CodingKey {
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            var imageContainer = container.nestedContainer(
                keyedBy: ImageURLCodingKeys.self,
                forKey: .imageURL
            )
            try imageContainer.encode(url, forKey: .url)
        }
    }
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
