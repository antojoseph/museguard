import Foundation

struct BrowserDownloadRequest: Codable {
    let downloadID: Int
    let phase: String
    let url: String?, finalURL: String?, filename: String?, mime: String?
    let state: String, danger: String?
    let fileSize: Int64?, totalBytes: Int64?
    let holdID: String?
    let ownedPause: Bool?
    enum CodingKeys: String, CodingKey {
        case downloadID = "download_id", phase, url, finalURL = "final_url", filename, mime, state, danger
        case fileSize = "file_size", totalBytes = "total_bytes", holdID = "hold_id", ownedPause = "owned_pause"
    }
    var isValid: Bool {
        downloadID >= 0 && ["metadata", "complete"].contains(phase) &&
        ["in_progress", "complete", "interrupted"].contains(state) &&
        [url, finalURL, filename].allSatisfy { Self.bounded($0, 4096) } &&
        Self.bounded(mime, 256) && Self.bounded(danger, 128) && Self.bounded(holdID, 128) &&
        (ownedPause != true || !(holdID ?? "").isEmpty) &&
        (fileSize ?? -1) >= -1 && (totalBytes ?? -1) >= -1
    }
    static func bounded(_ value: String?, _ bytes: Int) -> Bool {
        value == nil || (value!.utf8.count <= bytes && !value!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }
}
struct BrowserDownloadStatus: Codable {
    let downloadID: Int, status: String, sha256: String?, scanner: String, scanStatus: String
    let findings: [String], signatureStatus: String
    enum CodingKeys: String, CodingKey {
        case downloadID = "download_id", status, sha256, scanner, scanStatus = "scan_status", findings, signatureStatus = "signature_status"
    }
}
struct BrowserDownloadCommand: Codable, Equatable {
    let commandID: String, downloadID: Int, holdID: String, action: String
    enum CodingKeys: String, CodingKey { case commandID = "command_id", downloadID = "download_id", holdID = "hold_id", action }
}
struct BrowserDownloadCommandResult: Codable {
    let commandID: String, downloadID: Int, holdID: String, action: String, ok: Bool
    enum CodingKeys: String, CodingKey { case commandID = "command_id", downloadID = "download_id", holdID = "hold_id", action, ok }
    var isValid: Bool {
        UUID(uuidString: commandID) != nil && downloadID >= 0 && !(holdID.isEmpty) &&
        BrowserDownloadRequest.bounded(holdID, 128) && ["resume", "cancel", "show"].contains(action)
    }
}
struct BrowserSecretRequest: Codable {
    static let allowedCategories = Set(["private_key", "wallet_seed", "github_token", "openai_key", "anthropic_key", "stripe_secret_key", "slack_token", "aws_credentials"])
    let category: String, count: Int, categories: [String], phase: String
    var isValid: Bool {
        Self.allowedCategories.contains(category) && (1...8).contains(count) &&
        !categories.isEmpty && categories.count <= 8 && Set(categories).count == categories.count &&
        categories.contains(category) && categories.allSatisfy(Self.allowedCategories.contains) && ["paste", "submit"].contains(phase)
    }
}

extension BrowserRequest {
    var validTargetIdentity: Bool {
        guard let documentID, !documentID.isEmpty, BrowserDownloadRequest.bounded(documentID, 256),
              let tabID, tabID > 0, let windowID, windowID > 0, let pageRevision, pageRevision >= 0 else { return false }
        if let target { return target.documentID == documentID && target.revision == pageRevision && target.browserWindow.tabID == tabID && target.browserWindow.id == windowID }
        return true
    }
    func validatedSafetyRequest() throws -> BrowserRequest {
        guard action == nil, assessmentID == nil, purpose == nil, protectionEnabled == nil,
              contextRequestID == nil, contextError == nil, monitoringCommand == nil,
              pauseDurationMS == nil, monitoringRevision == nil else { throw BrowserProtocolError.invalidRequest }
        if type == "download-inspect" {
            guard let download, download.isValid, downloadCommand == nil, secret == nil, target == nil,
                  page == nil, tabID == nil, windowID == nil, documentID == nil, pageRevision == nil else { throw BrowserProtocolError.invalidRequest }
            // Strip credentials, query strings and fragments even though metadata
            // never enters the language model.
            let clean = BrowserDownloadRequest(downloadID: download.downloadID, phase: download.phase,
                url: try download.url.map(Self.cleanURL), finalURL: try download.finalURL.map(Self.cleanURL),
                filename: download.filename, mime: download.mime, state: download.state, danger: download.danger,
                fileSize: download.fileSize, totalBytes: download.totalBytes, holdID: download.holdID, ownedPause: download.ownedPause)
            return BrowserRequest(id: id, type: type, download: clean)
        }
        if type == "download-command-result" {
            guard let downloadCommand, downloadCommand.isValid, download == nil, secret == nil, target == nil,
                  page == nil, tabID == nil, windowID == nil, documentID == nil, pageRevision == nil else { throw BrowserProtocolError.invalidRequest }
            return self
        }
        guard download == nil, downloadCommand == nil, validTargetIdentity else { throw BrowserProtocolError.invalidRequest }
        if type == "target-update" {
            guard secret == nil, target != nil, page == nil else { throw BrowserProtocolError.invalidRequest }
            return self
        }
        if type == "target-invalidated" {
            guard secret == nil, target == nil, page == nil else { throw BrowserProtocolError.invalidRequest }
            return self
        }
        guard let secret, secret.isValid, let page, page.text.isEmpty, page.title.utf8.count <= 1200 else { throw BrowserProtocolError.invalidRequest }
        return BrowserRequest(id: id, type: type,
            page: Page(url: try Self.cleanURL(page.url), title: String(page.title.prefix(300)), text: ""),
            tabID: tabID, windowID: windowID, documentID: documentID, secret: secret, target: target, pageRevision: pageRevision)
    }
}

/// Only explicit native buttons create commands. Delivery is idempotent and
/// correlated to the individual Chrome download hold, with a short lifetime.
@MainActor
final class BrowserDownloadCommandBroker {
    private var commands: [(BrowserDownloadCommand, Date)] = []
    func enqueue(downloadID: Int, holdID: String, action: String) -> BrowserDownloadCommand {
        let command = BrowserDownloadCommand(commandID: UUID().uuidString, downloadID: downloadID, holdID: holdID, action: action)
        commands.append((command, Date().addingTimeInterval(30)))
        commands = Array(commands.suffix(32))
        return command
    }
    func pending() -> [BrowserDownloadCommand] {
        commands.removeAll { $0.1 < Date() }
        return commands.map(\.0)
    }
    func complete(_ result: BrowserDownloadCommandResult) -> Bool {
        guard let index = commands.firstIndex(where: { $0.0.commandID == result.commandID && $0.0.downloadID == result.downloadID && $0.0.holdID == result.holdID && $0.0.action == result.action }) else { return false }
        commands.remove(at: index)
        return true
    }
    func cancelAll() { commands.removeAll() }
}
