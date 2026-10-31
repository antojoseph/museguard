import Foundation

@main struct BrowserPredictionProtocolChecks {
    static func main() throws {
        let clock = Date()
        let timestamp = Int64(clock.timeIntervalSince1970 * 1_000)
        let sourceID = UUID().uuidString
        func prediction(source: String = sourceID, title: String = "Current page", tab: Int = 7,
            window: Int = 2, document: String? = "opaque-document", phase: String = "waiting",
            assessment: String? = nil, expires: Int64 = timestamp + 8_000) -> BrowserPredictionUpdate {
            BrowserPredictionUpdate(sourceID: source, title: title, tabID: tab, windowID: window,
                documentID: document, phase: phase, assessmentID: assessment, expiresAt: expires)
        }
        for phase in ["waiting", "checking", "completed", "unavailable"] {
            let update = prediction(phase: phase, assessment: ["checking", "completed"].contains(phase) ? "native-assessment" : nil)
            let validated = try update.validated(now: clock)
            assert(validated == update)
            let request = BrowserRequest(id: UUID().uuidString, type: "prediction-update", prediction: update)
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: encoded).validated()
            assert(decoded.prediction == update)
            let wire = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            assert(Set(wire.keys) == Set(["version", "id", "type", "mode", "prediction"]))
            let metadata = wire["prediction"] as! [String: Any]
            for forbidden in ["url", "text", "page", "risk_level", "summary", "guidance", "categories", "screenshot"] {
                assert(metadata[forbidden] == nil, "The extension supplies source correlation, never a model verdict or evidence.")
            }
        }
        for invalid in [
            prediction(source: "not-a-uuid"), prediction(title: String(repeating: "a", count: 251)),
            prediction(title: "Untrusted\ncontrol"), prediction(tab: 0), prediction(window: -1),
            prediction(document: ""), prediction(document: String(repeating: "a", count: 257)),
            prediction(document: "invalid\u{0001}"), prediction(phase: "paused"),
            prediction(phase: "checking"), prediction(phase: "completed"),
            prediction(phase: "completed", assessment: ""),
            prediction(phase: "completed", assessment: String(repeating: "a", count: 129)),
            prediction(phase: "completed", assessment: "invalid\u{0001}"),
            prediction(expires: timestamp), prediction(expires: timestamp + 10_001)
        ] {
            do { _ = try invalid.validated(now: clock); fatalError("Invalid prediction metadata accepted") } catch {}
        }
        let valid = prediction()
        let request = BrowserRequest(id: "prediction-wire", type: "prediction-update", prediction: valid)
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        let forbiddenFields: [String: Any] = [
            "page": ["url": "https://example.test/", "title": "Private page", "text": "PRIVATE_PAGE_TEXT"],
            "action": ["kind": "page"], "screenshot": "PRIVATE_PIXELS", "assessment_id": "other-assessment",
            "reason": "Extra instruction", "purpose": "proactive", "protection_enabled": true,
            "context_request_id": UUID().uuidString, "context_error": "Unexpected", "tab_id": 7, "window_id": 2,
            "document_id": "outer-document", "monitoring_command": "pause", "pause_duration_ms": 0,
            "prediction_source_id": UUID().uuidString,
            "monitoring_revision": 1, "download": ["download_id": 1, "phase": "metadata"],
            "download_command": ["download_id": 1, "hold_id": "hold", "command_id": "command", "action": "show", "ok": true],
            "secret": ["category": "private_key", "count": 1, "categories": ["private_key"], "phase": "paste"],
            "target": [:], "page_revision": 0,
            "browser_coverage": ["state": "completed", "assessment_id": "native-id", "checked_at": timestamp, "expires_at": timestamp + 1000]
        ]
        for (field, value) in forbiddenFields {
            var wire = base; wire[field] = value
            do {
                let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONSerialization.data(withJSONObject: wire))
                _ = try decoded.validated()
                fatalError("Prediction metadata accepted unrelated payload field: \(field)")
            } catch {}
        }
        for kind in ["status", "assess", "chat-context-result", "monitoring-state", "secret-paste"] {
            do { _ = try BrowserRequest(id: "wrong-route", type: kind, prediction: valid).validated(); fatalError("Wrong prediction route accepted") } catch {}
        }
        print("PASS: current-browser prediction metadata is bounded, short-lived, source-correlated and isolated from evidence, verdicts and controls")
    }
}
