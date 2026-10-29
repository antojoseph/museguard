import AppKit
import Foundation

@main struct LocalModelChecks {
    @MainActor static func main() async throws {
        let analyzer = LocalRiskAnalyzer()
        var results: [[String: Any]] = []
        var failures = 0
        for scenario in MockScenario.allCases {
            let start = Date()
            let snapshot = ScreenSnapshot(appName: "Muse Mock Lab", windowTitle: scenario.title, text: scenario.text)
            let image = scenario.imageDataURL()
            let verdict: RiskVerdict
            if let image { verdict = try await analyzer.analyze(snapshot: snapshot, screenshotDataURL: image, model: LocalModelConfiguration.model) }
            else { verdict = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model) }
            let warns = verdict.riskLevel == .medium || verdict.riskLevel == .high
            let passes = scenario.expectsWarning ? warns : (verdict.riskLevel == .safe || verdict.riskLevel == .low)
            if !passes { failures += 1 }
            let elapsed = Date().timeIntervalSince(start)
            results.append(["scenario": scenario.rawValue, "vision": image != nil, "risk": verdict.riskLevel.rawValue, "summary": verdict.summary, "guidance": verdict.guidance, "seconds": elapsed, "passed": passes])
            print("\(passes ? "PASS" : "FAIL") \(scenario.rawValue): \(verdict.riskLevel.rawValue), \(String(format: "%.1f", elapsed))s · \(verdict.summary)")
            fflush(stdout)
            if scenario == .phishing {
                let context = RiskReportChatContext(sourceLabel: "Mock lab", appName: snapshot.appName, windowTitle: snapshot.windowTitle, riskLevel: verdict.riskLevel, summary: verdict.summary, guidance: verdict.guidance, categories: verdict.categories)
                let answer = try await analyzer.answerQuestion("Why should I stop?", context: context, model: LocalModelConfiguration.model)
                assert(!answer.isEmpty)
                print("PASS follow-up: \(answer)")
                results.append(["scenario": "follow-up", "answer": answer, "passed": true])
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "build/local-model-results.json"))
        if failures > 0 { exit(1) }
    }
}
