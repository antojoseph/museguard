import Foundation

@main struct BrowserSafetyProtocolChecks {
    @MainActor static func main() throws {
        func rejects(_ wire: [String: Any]) -> Bool {
            do { _ = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: wire)).validated(); return false }
            catch { return true }
        }
        var secret: [String: Any] = ["version":1,"id":"paste-1","type":"secret-paste","mode":"text",
            "page":["url":"https://example.test/chat?private=redacted","title":"Chat","text":""],
            "document_id":"document-nonce","page_revision":4,"tab_id":3,"window_id":2,
            "secret":["category":"private_key","categories":["private_key"],"count":1,"phase":"paste"]]
        let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: secret)).validated()
        assert(decoded.page?.url == "https://example.test/chat")
        secret["page"] = ["url":"https://example.test/","title":"Chat","text":"must never carry pasted data"]
        assert(rejects(secret))
        secret["page"] = ["url":"https://example.test/","title":"Chat","text":""]
        secret["secret"] = ["category":"ordinary_password","categories":["ordinary_password"],"count":1,"phase":"paste"]
        assert(rejects(secret))
        secret["secret"] = ["category":"private_key","categories":["private_key"],"count":0,"phase":"paste"]
        assert(rejects(secret))
        var download: [String: Any] = ["version":1,"id":"file-1","type":"download-inspect","download":["download_id":7,"phase":"metadata","state":"in_progress","url":"https://user:pass@example.test/file?key=private","hold_id":"hold-7","owned_pause":true]]
        let clean = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: download)).validated()
        assert(clean.download?.url == "https://example.test/file")
        download["download"] = ["download_id":7,"phase":"metadata","state":"in_progress","owned_pause":true]
        assert(rejects(download))
        download["type"] = "assess"
        assert(rejects(download), "Download fields cannot be smuggled into inference requests")
        let noGeometry = BrowserRequest(id: "present-no-geometry", type: "present-block", assessmentID: "original-finding",
            tabID: 3, windowID: 2, documentID: "document-nonce", pageRevision: 4)
        let validNoGeometry = try noGeometry.validated()
        assert(validNoGeometry.documentID == "document-nonce")
        let broker = BrowserDownloadCommandBroker()
        let command = broker.enqueue(downloadID:7,holdID:"hold-7",action:"resume")
        assert(broker.pending() == [command])
        assert(!broker.complete(.init(commandID:command.commandID,downloadID:8,holdID:"hold-7",action:"resume",ok:true)))
        assert(!broker.complete(.init(commandID:command.commandID,downloadID:7,holdID:"stale",action:"resume",ok:true)))
        assert(broker.complete(.init(commandID:command.commandID,downloadID:7,holdID:"hold-7",action:"resume",ok:true)))
        assert(broker.pending().isEmpty)
        assert(!broker.complete(.init(commandID:command.commandID,downloadID:7,holdID:"hold-7",action:"resume",ok:true)))
        print("PASS: secret metadata boundaries, download URL redaction, command hold correlation and idempotence")
    }
}
