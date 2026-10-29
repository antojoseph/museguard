import Foundation
import ImageIO

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

    init(version: Int = 1, id: String, type: String, mode: String = "text", page: Page? = nil, action: Action? = nil, screenshot: String? = nil, assessmentID: String? = nil, reason: String? = nil, purpose: String? = nil) {
        self.version = version; self.id = id; self.type = type; self.mode = mode
        self.page = page; self.action = action; self.screenshot = screenshot; self.assessmentID = assessmentID; self.reason = reason
        self.purpose = purpose
    }
    private enum CodingKeys: String, CodingKey {
        case version, id, type, mode, page, action, screenshot, reason, purpose
        case assessmentID = "assessment_id"
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
    }
    func validated() throws -> BrowserRequest {
        guard version == 1, !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["status", "assess", "present", "present-block", "decision", "cancel", "notice", "finish-checking"].contains(type), ["text", "vision"].contains(mode) else {
            throw BrowserProtocolError.invalidRequest
        }
        if ["status", "present", "present-block", "decision", "cancel", "finish-checking"].contains(type) {
            guard page == nil, action == nil, screenshot == nil, reason == nil, purpose == nil else { throw BrowserProtocolError.invalidRequest }
            if type != "status" {
                guard let assessmentID, !assessmentID.isEmpty, assessmentID.utf8.count <= 128,
                      !assessmentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BrowserProtocolError.invalidRequest }
            } else if assessmentID != nil { throw BrowserProtocolError.invalidRequest }
            return self
        }
        guard assessmentID == nil else { throw BrowserProtocolError.invalidRequest }
        if let purpose {
            guard type == "assess", mode == "text", ["proactive", "intent"].contains(purpose) else { throw BrowserProtocolError.invalidRequest }
        }
        if type == "notice" {
            guard mode == "text", screenshot == nil, let reason,
                  ["unavailable", "changed", "unsupported", "open_failed", "checking"].contains(reason) else { throw BrowserProtocolError.invalidRequest }
        } else if reason != nil { throw BrowserProtocolError.invalidRequest }
        guard let page, page.title.count <= 300, page.title.utf8.count <= 1_200,
              page.text.count <= 8_000, page.text.utf8.count <= 32_000,
              page.url.utf8.count <= 4_096 else { throw BrowserProtocolError.invalidRequest }
        let cleanPage = Page(url: try Self.cleanURL(page.url), title: Self.cleanText(page.title), text: Self.cleanText(page.text))
        var cleanAction: Action?
        if let action {
            guard ["page", "link", "submit"].contains(action.kind), (action.label?.count ?? 0) <= 512,
                  (action.label?.utf8.count ?? 0) <= 2_048,
                  (action.method?.count ?? 0) <= 16, (action.url?.utf8.count ?? 0) <= 4_096 else { throw BrowserProtocolError.invalidRequest }
            // Background page/link descriptors may serialize an absent DOM
            // method as an empty string. Navigations use GET; never infer POST.
            let suppliedMethod = action.method?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let method = suppliedMethod == nil || (action.kind != "submit" && suppliedMethod == "") ? "GET" : suppliedMethod!
            guard ["GET", "POST", "DIALOG"].contains(method) else { throw BrowserProtocolError.invalidRequest }
            cleanAction = Action(kind: action.kind, url: try action.url.map(Self.cleanURL), label: action.label.map(Self.cleanText), method: method, sensitive: action.sensitive)
        }
        if mode == "vision" {
            guard let screenshot, screenshot.utf8.count <= 2_000_000 else { throw BrowserProtocolError.invalidScreenshot }
            let prefix = screenshot.hasPrefix("data:image/png;base64,") ? "data:image/png;base64," : "data:image/jpeg;base64,"
            guard screenshot.hasPrefix(prefix), let data = Data(base64Encoded: String(screenshot.dropFirst(prefix.count))),
                  data.count >= 8,
                  (prefix.contains("png") ? data.starts(with: [137,80,78,71,13,10,26,10]) : data.starts(with: [255,216,255])) else { throw BrowserProtocolError.invalidScreenshot }
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as NSDictionary?,
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw BrowserProtocolError.invalidScreenshot }
            let w = width.int64Value, h = height.int64Value
            guard w > 0, h > 0, w <= 4_096, h <= 4_096, w*h <= 8_000_000 else { throw BrowserProtocolError.invalidScreenshot }
        } else if screenshot != nil { throw BrowserProtocolError.invalidRequest }
        return BrowserRequest(id: id, type: type, mode: mode, page: cleanPage, action: cleanAction, screenshot: screenshot, reason: reason, purpose: purpose)
    }
    private static func cleanText(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
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
    let actionState: String?
    let lastAssessment: AssessmentMetadata?
    let completedAssessments: Int?
    enum CodingKeys: String, CodingKey {
        case version, id, ok, decision, summary, guidance, categories, mode, error
        case riskLevel = "risk_level", durationMS = "duration_ms", modelReady = "model_ready", actionState = "action_state"
        case lastAssessment = "last_assessment", completedAssessments = "completed_assessments"
    }
    init(id: String, ok: Bool, decision: String, riskLevel: String, summary: String, guidance: String, categories: [String] = [], mode: String = "text", durationMS: Int = 0, error: String? = nil, modelReady: Bool? = nil, actionState: String? = nil, lastAssessment: AssessmentMetadata? = nil, completedAssessments: Int? = nil) {
        self.id = id; self.ok = ok; self.decision = decision; self.riskLevel = riskLevel
        self.summary = summary; self.guidance = guidance; self.categories = categories; self.mode = mode
        self.durationMS = durationMS; self.error = error; self.modelReady = modelReady; self.actionState = actionState
        self.lastAssessment = lastAssessment; self.completedAssessments = completedAssessments
    }
    static func failure(id: String, mode: String = "text", message: String, actionState: String? = nil) -> BrowserResponse {
        BrowserResponse(id: id, ok: false, decision: "review", riskLevel: "unknown", summary: "Muse could not check this action.", guidance: message, mode: mode, error: message, actionState: actionState)
    }
}

enum BrowserProtocolError: LocalizedError {
    case invalidRequest, invalidURL, invalidScreenshot, frameTooLarge, truncatedFrame, unavailable, socketPathTooLong, alreadyRunning
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The browser request was not valid."
        case .invalidURL: return "Only HTTP and HTTPS page or action URLs can be checked."
        case .invalidScreenshot: return "The screenshot was not a supported, bounded PNG or JPEG image."
        case .frameTooLarge: return "The browser message exceeded the local size limit."
        case .truncatedFrame: return "The browser connection ended before its message was complete."
        case .unavailable: return "Muse Guard is unavailable. Open the companion app and try again."
        case .socketPathTooLong: return "The local browser bridge path is too long for this Mac."
        case .alreadyRunning: return "A Muse Guard browser bridge is already running."
        }
    }
}
