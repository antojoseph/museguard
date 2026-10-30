import Foundation

/// Page evidence is untrusted input. This protocol carries no model credential.
struct BrowserRequest: Codable {
    static let maximumFrameBytes = 2_100_000
    struct Page: Codable {
        let url: String
        let title: String
        let text: String
    }
    struct Action: Codable {
        let kind: String
        let url: String?
        let label: String?
        let method: String?
        let sensitive: Bool?
    }
    let version: Int
    let id: String
    let type: String
    let mode: String
    let page: Page?
    let action: Action?
    let screenshot: String?
    let assessmentID: String?
    let reason: String?
    let purpose: String?
    let protectionEnabled: Bool?
    let contextRequestID: String?
    let contextError: String?
    let tabID: Int?
    let windowID: Int?
    let documentID: String?
    let monitoringCommand: String?
    let pauseDurationMS: Int?
    let monitoringRevision: Int64?

    init(version: Int = 1, id: String, type: String, mode: String = "text", page: Page? = nil, action: Action? = nil, screenshot: String? = nil, assessmentID: String? = nil, reason: String? = nil, purpose: String? = nil, protectionEnabled: Bool? = nil, contextRequestID: String? = nil, contextError: String? = nil, tabID: Int? = nil, windowID: Int? = nil, documentID: String? = nil, monitoringCommand: String? = nil, pauseDurationMS: Int? = nil, monitoringRevision: Int64? = nil) {
        self.version = version; self.id = id; self.type = type; self.mode = mode
        self.page = page; self.action = action; self.screenshot = screenshot; self.assessmentID = assessmentID; self.reason = reason
        self.purpose = purpose
        self.protectionEnabled = protectionEnabled
        self.contextRequestID = contextRequestID; self.contextError = contextError
        self.tabID = tabID; self.windowID = windowID; self.documentID = documentID
        self.monitoringCommand = monitoringCommand; self.pauseDurationMS = pauseDurationMS; self.monitoringRevision = monitoringRevision
    }
    private enum CodingKeys: String, CodingKey {
        case version, id, type, mode, page, action, screenshot, reason, purpose
        case assessmentID = "assessment_id"
        case protectionEnabled = "protection_enabled"
        case contextRequestID = "context_request_id", contextError = "context_error"
        case tabID = "tab_id", windowID = "window_id", documentID = "document_id"
        case monitoringCommand = "monitoring_command", pauseDurationMS = "pause_duration_ms", monitoringRevision = "monitoring_revision"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "text"
        page = try values.decodeIfPresent(Page.self, forKey: .page)
        action = try values.decodeIfPresent(Action.self, forKey: .action)
        screenshot = try values.decodeIfPresent(String.self, forKey: .screenshot)
        assessmentID = try values.decodeIfPresent(String.self, forKey: .assessmentID)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        purpose = try values.decodeIfPresent(String.self, forKey: .purpose)
        protectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .protectionEnabled)
        contextRequestID = try values.decodeIfPresent(String.self, forKey: .contextRequestID)
        contextError = try values.decodeIfPresent(String.self, forKey: .contextError)
        tabID = try values.decodeIfPresent(Int.self, forKey: .tabID)
        windowID = try values.decodeIfPresent(Int.self, forKey: .windowID)
        documentID = try values.decodeIfPresent(String.self, forKey: .documentID)
        monitoringCommand = try values.decodeIfPresent(String.self, forKey: .monitoringCommand)
        pauseDurationMS = try values.decodeIfPresent(Int.self, forKey: .pauseDurationMS)
        monitoringRevision = try values.decodeIfPresent(Int64.self, forKey: .monitoringRevision)
    }
    func validated() throws -> BrowserRequest {
        guard version == 1, !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), mode == "text",
              ["status", "assess", "present-block", "cancel", "protection-state", "chat-context-poll", "chat-context-result", "monitoring-state", "monitoring-control"].contains(type),
              screenshot == nil, reason == nil else { throw BrowserProtocolError.invalidRequest }
        if ["monitoring-state", "monitoring-control"].contains(type) {
            guard page == nil, action == nil, assessmentID == nil, purpose == nil, protectionEnabled == nil,
                  contextRequestID == nil, contextError == nil, tabID == nil, windowID == nil, documentID == nil,
                  monitoringRevision == nil || monitoringRevision! > 0 else { throw BrowserProtocolError.invalidRequest }
            if type == "monitoring-state" {
                guard monitoringCommand == nil, pauseDurationMS == nil else { throw BrowserProtocolError.invalidRequest }
            } else {
                guard ["pause", "resume"].contains(monitoringCommand ?? ""),
                      monitoringCommand == "pause" ? [0, 1_800_000].contains(pauseDurationMS ?? -1) : pauseDurationMS == nil else { throw BrowserProtocolError.invalidRequest }
            }
            return self
        }
        guard monitoringCommand == nil, pauseDurationMS == nil, monitoringRevision == nil else { throw BrowserProtocolError.invalidRequest }
        if type == "chat-context-result" {
            guard let contextRequestID, UUID(uuidString: contextRequestID) != nil,
                  action == nil, assessmentID == nil, purpose == nil, protectionEnabled == nil else { throw BrowserProtocolError.invalidRequest }
            if let contextError {
                guard !contextError.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, contextError.utf8.count <= 256,
                      !contextError.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
                      page == nil, tabID == nil, windowID == nil, documentID == nil else { throw BrowserProtocolError.invalidRequest }
                return self
            }
            guard let page, let tabID, tabID > 0, let windowID, windowID > 0,
                  let documentID, !documentID.isEmpty, documentID.utf8.count <= 256,
                  !documentID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw BrowserProtocolError.invalidRequest }
            return BrowserRequest(id:id,type:type,page:try Self.validatedPage(page),contextRequestID:contextRequestID,
                tabID:tabID,windowID:windowID,documentID:documentID)
        }
        guard contextRequestID == nil, contextError == nil, tabID == nil, windowID == nil, documentID == nil else { throw BrowserProtocolError.invalidRequest }
        if type == "protection-state" {
            guard protectionEnabled != nil, page == nil, action == nil, assessmentID == nil, purpose == nil else { throw BrowserProtocolError.invalidRequest }
            return self
        }
        guard protectionEnabled == nil else { throw BrowserProtocolError.invalidRequest }
        if ["status", "chat-context-poll", "present-block", "cancel"].contains(type) {
            guard page == nil, action == nil, purpose == nil else { throw BrowserProtocolError.invalidRequest }
            if ["present-block", "cancel"].contains(type) {
                guard let assessmentID, !assessmentID.isEmpty, assessmentID.utf8.count <= 128,
                      !assessmentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BrowserProtocolError.invalidRequest }
            } else if assessmentID != nil { throw BrowserProtocolError.invalidRequest }
            return self
        }
        guard assessmentID == nil, ["proactive", "intent"].contains(purpose ?? ""), let page else { throw BrowserProtocolError.invalidRequest }
        let cleanPage = try Self.validatedPage(page)
        var cleanAction: Action?
        if let action {
            guard ["page", "link", "submit"].contains(action.kind), (action.label?.count ?? 0) <= 512,
                  (action.label?.utf8.count ?? 0) <= 2_048,
                  (action.method?.count ?? 0) <= 16, (action.url?.utf8.count ?? 0) <= 4_096 else { throw BrowserProtocolError.invalidRequest }
            let supplied = action.method?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let method = supplied == nil || (action.kind != "submit" && supplied == "") ? "GET" : supplied!
            guard ["GET", "POST", "DIALOG"].contains(method) else { throw BrowserProtocolError.invalidRequest }
            cleanAction = Action(kind: action.kind, url: try action.url.map(Self.cleanURL), label: action.label.map(Self.cleanText), method: method, sensitive: action.sensitive)
        }
        return BrowserRequest(id: id, type: type, page: cleanPage, action: cleanAction, purpose: purpose)
    }
    private static func cleanText(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
    }
    private static func validatedPage(_ page: Page) throws -> Page {
        guard page.title.count <= 300, page.title.utf8.count <= 1_200,
              page.text.count <= 8_000, page.text.utf8.count <= 32_000, page.url.utf8.count <= 4_096 else { throw BrowserProtocolError.invalidRequest }
        return Page(url:try cleanURL(page.url),title:cleanText(page.title),text:cleanText(page.text))
    }
    static func cleanURL(_ value: String) throws -> String {
        guard var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BrowserProtocolError.invalidURL }
        parts.scheme = scheme; parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        guard let result = parts.url?.absoluteString else { throw BrowserProtocolError.invalidURL }
        return result
    }
}

struct BrowserResponse: Codable {
    struct MonitoringState: Codable, Equatable {
        let paused: Bool
        let pauseUntil: Int64
        let revision: Int64
        enum CodingKeys: String, CodingKey { case paused, revision; case pauseUntil = "pause_until" }
    }
    /// Status diagnostics deliberately exclude all page and action evidence.
    /// The coordinator retains only the most recently finished assessment.
    struct AssessmentMetadata: Codable {
        let id: String
        let kind: String
        let riskLevel: String
        let ok: Bool
        let completedAt: Int64
        enum CodingKeys: String, CodingKey {
            case id, kind, ok
            case riskLevel = "risk_level", completedAt = "completed_at"
        }
    }
    var version = 1
    let id: String
    let ok: Bool
    let decision: String
    let riskLevel: String
    let summary: String
    let guidance: String
    let categories: [String]
    let mode: String
    let durationMS: Int
    let error: String?
    let modelReady: Bool?
    let lastAssessment: AssessmentMetadata?
    let completedAssessments: Int?
    let contextRequestID: String?
    let contextExpiresAt: Int64?
    let monitoring: MonitoringState?
    enum CodingKeys: String, CodingKey {
        case version, id, ok, decision, summary, guidance, categories, mode, error, monitoring
        case riskLevel = "risk_level", durationMS = "duration_ms", modelReady = "model_ready"
        case lastAssessment = "last_assessment", completedAssessments = "completed_assessments"
        case contextRequestID = "context_request_id", contextExpiresAt = "context_expires_at"
    }
    init(id: String, ok: Bool, decision: String, riskLevel: String, summary: String, guidance: String, categories: [String] = [], mode: String = "text", durationMS: Int = 0, error: String? = nil, modelReady: Bool? = nil, lastAssessment: AssessmentMetadata? = nil, completedAssessments: Int? = nil, contextRequestID: String? = nil, contextExpiresAt: Int64? = nil, monitoring: MonitoringState? = nil) {
        self.id = id; self.ok = ok; self.decision = decision; self.riskLevel = riskLevel
        self.summary = summary; self.guidance = guidance; self.categories = categories; self.mode = mode
        self.durationMS = durationMS; self.error = error; self.modelReady = modelReady
        self.lastAssessment = lastAssessment; self.completedAssessments = completedAssessments
        self.contextRequestID = contextRequestID; self.contextExpiresAt = contextExpiresAt
        self.monitoring = monitoring
    }
    static func failure(id: String, mode: String = "text", message: String) -> BrowserResponse {
        BrowserResponse(id: id, ok: false, decision: "review", riskLevel: "unknown", summary: "Muse could not complete this check.", guidance: message, mode: mode, error: message)
    }
}

enum BrowserProtocolError: LocalizedError {
    case invalidRequest, invalidURL, frameTooLarge, truncatedFrame, unavailable, socketPathTooLong, alreadyRunning
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The browser request was not valid."
        case .invalidURL: return "Only HTTP and HTTPS page or action URLs can be checked."
        case .frameTooLarge: return "The browser message exceeded the local size limit."
        case .truncatedFrame: return "The browser connection ended before its message was complete."
        case .unavailable: return "Muse Guard is unavailable. Open the companion app and try again."
        case .socketPathTooLong: return "The local browser bridge path is too long for this Mac."
        case .alreadyRunning: return "A Muse Guard browser bridge is already running."
        }
    }
}
