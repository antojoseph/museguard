import Foundation

@main struct PredictionDebugChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func verdict(_ risk: RiskLevel, _ summary: String = "Observed model judgment") -> RiskVerdict {
            RiskVerdict(riskLevel: risk, summary: summary, guidance: "Not part of the HUD", categories: [])
        }
        let a = "private:browser:window-1:tab-a:document-1:revision-1"
        let b = "private:browser:window-1:tab-b:document-2:revision-1"

        var state = PredictionDebugState()
        assert(state.snapshot(now: now) == .initial)
        state.setCurrentSource(key: a, kind: .browser, heading: "Chrome · Page A", now: now)
        assert(state.snapshot(now: now).phase == .waiting)
        assert(state.begin(sourceKey: a, requestID: "a-1", now: now))
        assert(state.snapshot(now: now).phase == .checking && state.snapshot(now: now).riskLevel == nil)
        assert(state.complete(sourceKey: a, requestID: "a-1", verdict: verdict(.medium, "A caution"), now: now))
        assert(state.snapshot(now: now).riskLevel == .medium && state.snapshot(now: now).summary == "A caution")
        assert(state.snapshot(now: now).timestamp == now)

        // A tab switch clears A immediately. A completion from A must not
        // become the prediction for the newly current B.
        state.setCurrentSource(key: b, kind: .browser, heading: "Chrome · Page B", now: now)
        assert(state.snapshot(now: now).phase == .waiting && state.snapshot(now: now).summary == nil)
        assert(state.begin(sourceKey: a, requestID: "a-background", now: now))
        assert(state.complete(sourceKey: a, requestID: "a-background", verdict: verdict(.high, "Background A"), now: now))
        assert(state.snapshot(now: now).phase == .waiting && state.snapshot(now: now).riskLevel == nil)
        assert(state.begin(sourceKey: b, requestID: "b-old", now: now))
        assert(state.begin(sourceKey: b, requestID: "b-new", now: now.addingTimeInterval(1)))
        assert(!state.complete(sourceKey: b, requestID: "b-old", verdict: verdict(.high), now: now.addingTimeInterval(2)))
        assert(!state.complete(sourceKey: a, requestID: "b-new", verdict: verdict(.high), now: now.addingTimeInterval(2)))
        assert(state.snapshot(now: now.addingTimeInterval(2)).phase == .checking)
        assert(state.complete(sourceKey: b, requestID: "b-new", verdict: verdict(.safe, "B is assessed safe"), now: now.addingTimeInterval(3)))
        assert(state.snapshot(now: now.addingTimeInterval(3)).riskLevel == .safe)
        assert(!state.begin(sourceKey: a, requestID: "b-new", now: now.addingTimeInterval(4)), "Request IDs cannot migrate to another source.")
        assert(!state.fail(sourceKey: b, requestID: "unrelated", now: now))

        // Activity changing while inference runs is normal, not a capture or
        // model failure. Its discarded result can never complete afterward.
        var changing = PredictionDebugState()
        changing.setCurrentSource(key: a, kind: .desktopVisual, heading: "Chat app", now: now)
        assert(changing.begin(sourceKey: a, requestID: "changing", now: now))
        assert(!changing.discard(sourceKey: a, requestID: "unrelated", now: now))
        assert(changing.discard(sourceKey: a, requestID: "changing", now: now))
        let discarded = changing.snapshot(now: now)
        assert(discarded.phase == .waiting && discarded.riskLevel == nil)
        assert(discarded.statusDetail?.contains("Activity changed") == true)
        assert(!changing.complete(sourceKey: a, requestID: "changing", verdict: verdict(.safe), now: now))
        assert(changing.begin(sourceKey: a, requestID: "failed", now: now))
        assert(changing.fail(sourceKey: a, requestID: "failed", detail: "Local model timed out.", now: now))
        assert(changing.snapshot(now: now).phase == .unavailable)
        assert(changing.snapshot(now: now).statusDetail == "Local model timed out.")
        assert(changing.begin(sourceKey: a, requestID: "retry", now: now))
        assert(changing.snapshot(now: now).statusDetail == nil)
        assert(changing.complete(sourceKey: a, requestID: "retry", verdict: verdict(.safe), now: now))
        assert(!changing.discard(sourceKey: a, requestID: "unstarted-sample", now: now))
        assert(changing.snapshot(now: now).riskLevel == .safe)

        // Identical content/title in a new document or a new page revision
        // cannot inherit a verdict through a shared or redacted URL.
        let newDocument = "private:browser:window-1:tab-b:document-NEW:revision-1"
        state.setCurrentSource(key: newDocument, kind: .browser, heading: "Chrome · Page B", now: now)
        assert(state.snapshot(now: now).phase == .waiting && state.snapshot(now: now).riskLevel == nil)
        assert(!state.complete(sourceKey: newDocument, requestID: "b-new", verdict: verdict(.safe), now: now))
        assert(state.begin(sourceKey: newDocument, requestID: "new-document", now: now))
        assert(state.complete(sourceKey: newDocument, requestID: "new-document", verdict: verdict(.unknown), now: now))
        let unknown = state.snapshot(now: now)
        assert(unknown.phase == .completed && unknown.riskLevel == .unknown, "A completed unknown assessment must never be labeled safe.")
        state.setCurrentSource(key: newDocument + ":page-change", kind: .browser, heading: "Chrome · Page B", now: now)
        assert(state.snapshot(now: now).phase == .waiting && state.snapshot(now: now).summary == nil)

        // Pause/resume and stop/start revoke old work and cached results. The
        // old receipt cannot be registered as new work to resurrect its risk.
        var pauses = PredictionDebugState()
        pauses.setCurrentSource(key: a, kind: .browser, heading: "Chrome · Page A", now: now)
        assert(pauses.begin(sourceKey: a, requestID: "pre-pause", now: now))
        pauses.setPaused(true, now: now.addingTimeInterval(1))
        assert(pauses.snapshot(now: now).phase == .paused && pauses.snapshot(now: now).riskLevel == nil)
        assert(!pauses.complete(sourceKey: a, requestID: "pre-pause", verdict: verdict(.high), now: now))
        pauses.setPaused(false, now: now.addingTimeInterval(2))
        assert(pauses.snapshot(now: now).phase == .waiting)
        assert(!pauses.begin(sourceKey: a, requestID: "pre-pause", now: now))
        assert(pauses.begin(sourceKey: a, requestID: "post-pause", now: now))
        assert(pauses.complete(sourceKey: a, requestID: "post-pause", verdict: verdict(.low), now: now))
        pauses.setStopped(true, now: now)
        assert(pauses.snapshot(now: now).phase == .stopped && pauses.snapshot(now: now).summary == nil)
        pauses.setStopped(false, now: now)
        assert(pauses.snapshot(now: now).phase == .waiting)
        assert(!pauses.begin(sourceKey: a, requestID: "post-pause", now: now))

        var freshness = PredictionDebugState(freshness: 10, checkingTimeout: 5)
        freshness.setCurrentSource(key: a, kind: .desktopText, heading: "Notes", now: now)
        assert(freshness.begin(sourceKey: a, requestID: "slow", now: now))
        assert(freshness.snapshot(now: now.addingTimeInterval(5)).phase == .stale)
        assert(freshness.fail(sourceKey: a, requestID: "slow", now: now.addingTimeInterval(6)))
        assert(freshness.snapshot(now: now.addingTimeInterval(1_000)).phase == .unavailable)
        assert(freshness.begin(sourceKey: a, requestID: "fresh", now: now))
        assert(freshness.complete(sourceKey: a, requestID: "fresh", verdict: verdict(.medium), now: now))
        assert(freshness.snapshot(now: now.addingTimeInterval(9)).phase == .completed)
        let stale = freshness.snapshot(now: now.addingTimeInterval(10))
        assert(stale.phase == .stale && stale.riskLevel == nil && stale.summary == nil && stale.timestamp == now)
        assert(!freshness.begin(sourceKey: a, requestID: "fresh", now: now.addingTimeInterval(20)))
        assert(!freshness.complete(sourceKey: a, requestID: "fresh", verdict: verdict(.safe), now: now.addingTimeInterval(20)))
        assert(freshness.snapshot(now: now.addingTimeInterval(20)).phase == .stale, "Repeated receipt delivery cannot extend freshness.")
        assert(freshness.snapshot(now: now.addingTimeInterval(-5)).phase == .stale, "A future timestamp must not manufacture fresh results after a clock change.")

        // Background cache pressure is bounded and cannot evict the actual
        // current source merely because other tabs are producing results.
        var bounded = PredictionDebugState(maxCachedSources: 2)
        bounded.setCurrentSource(key: a, kind: .browser, heading: "Current", now: now)
        assert(bounded.begin(sourceKey: a, requestID: "keep-current", now: now))
        assert(bounded.complete(sourceKey: a, requestID: "keep-current", verdict: verdict(.unknown), now: now))
        for index in 0..<100 {
            let key = "background-source-\(index)", id = "background-request-\(index)"
            assert(bounded.begin(sourceKey: key, requestID: id, now: now))
            assert(bounded.complete(sourceKey: key, requestID: id, verdict: verdict(.high), now: now))
            assert(bounded.cachedSourceCount <= 2)
            assert(bounded.snapshot(now: now).riskLevel == .unknown)
        }
        assert(!bounded.complete(sourceKey: "background-source-0", requestID: "background-request-0", verdict: verdict(.high), now: now))

        var display = PredictionDebugState(sanitizeSummary: { $0.contains("DO_NOT_DISPLAY_SECRET") ? nil : $0 })
        display.setCurrentSource(key: "opaque-key-never-expose-this", kind: .desktopVisual,
            heading: String(repeating: "🙂", count: 100) + " https://private.example/route?token=private", now: now)
        assert(display.begin(sourceKey: "opaque-key-never-expose-this", requestID: "display-1", now: now))
        assert(display.complete(sourceKey: "opaque-key-never-expose-this", requestID: "display-1",
            verdict: verdict(.high, "DO_NOT_DISPLAY_SECRET"), now: now))
        let hiddenSummary = display.snapshot(now: now)
        assert(hiddenSummary.riskLevel == .high && hiddenSummary.summary == nil, "A sanitizer can hide sensitive output without changing model severity.")
        assert(hiddenSummary.heading.utf8.count <= 240 && !hiddenSummary.heading.contains("�"))
        assert(display.begin(sourceKey: "opaque-key-never-expose-this", requestID: "display-2", now: now))
        assert(display.complete(sourceKey: "opaque-key-never-expose-this", requestID: "display-2",
            verdict: verdict(.medium, "Observed https://private.example/path?token=secret\n" + String(repeating: "🙂", count: 300)), now: now))
        let safeSummary = display.snapshot(now: now)
        assert((safeSummary.summary?.utf8.count ?? 0) <= 600 && safeSummary.summary?.contains("�") == false)
        assert(safeSummary.summary?.contains("token=secret") == false && safeSummary.summary?.contains("\n") == false)
        assert(Set(Mirror(reflecting: safeSummary).children.compactMap(\.label)) == Set(["phase", "kind", "heading", "riskLevel", "summary", "timestamp", "statusDetail"]))
        display.clearCurrentSource(now: now)
        assert(display.snapshot(now: now).phase == .waiting && display.snapshot(now: now).summary == nil)
        display.setCurrentSource(key: "", kind: .browser, heading: "Invalid", now: now)
        assert(display.snapshot(now: now).kind == nil)

        print("PASS: prediction source/request correlation, tab/document/revision changes, unknown severity, pause/stop revocation, freshness, cache bounds and display-only summaries")
    }
}
