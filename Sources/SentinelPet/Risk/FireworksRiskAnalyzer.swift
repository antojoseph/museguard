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
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw FireworksRiskAnalyzerError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages(for: snapshot),
                responseFormat: ResponseFormat(type: "json_object"),
                temperature: 0.1,
                maxTokens: 360
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
                content: """
                You are Sentinel Pet, a local desktop security assistant. Evaluate text from a focused macOS window for user-facing risk: phishing, credential theft, payment scams, remote-access scams, malware/social engineering, suspicious links, impersonation, urgency pressure, and account takeover. Return only JSON with keys risk_level, summary, guidance, categories. risk_level must be one of safe, low, medium, high. Keep summary and guidance concise.
                """
            ),
            ChatMessage(
                role: "user",
                content: """
                App: \(snapshot.appName)
                Window: \(snapshot.windowTitle ?? "unknown")

                Focused-window text:
                \(snapshot.text)
                """
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
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
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
