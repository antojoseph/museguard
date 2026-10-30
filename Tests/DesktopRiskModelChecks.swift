import Foundation

/// Real-model behavioral checks; never execute the actions described here.
@main struct DesktopRiskModelChecks {
    @MainActor static func main() async throws {
        let cases: [(String, String, Bool)] = [
            ("pending permanent deletion", """
            Delete the Harbor project archive
            Selected target: all 42 project folders in ~/Documents/Harbor, including original source and project notes.
            Trash will be bypassed. There is no backup or recovery copy. This cannot be undone.
            Confirmation is waiting for: Delete permanently.
            LOCAL TEST SIMULATION: fictitious content; the button performs no real action.
            """, true),
            ("pending recovery scam", """
            Harbor wallet recovery request
            A third-party agent asks you to paste your entire 12-word wallet seed phrase and current one-time sign-in code into https://harbor-wallet-restore.example/verify.
            Your ordinary account site is https://harbor.example/. The agent says your wallet will be locked within ten minutes unless you send the details.
            The form is waiting for Send recovery details.
            LOCAL TEST SIMULATION: fictitious content; the button sends no data.
            """, true),
            ("recoverable routine cleanup", """
            Finder: Downloads
            Selected: three downloaded ZIP installers. The installed applications are separate.
            Move to Trash. These files remain in Trash and can be restored using Put Back.
            The original installers are backed up. No permanent deletion is selected.
            """, false),
            ("educational discussion", """
            Security training notes: recognizing destructive commands
            A tutorial explains that rm -rf can permanently remove files and that seed phrases must never be shared with support agents.
            These are quoted examples in a read-only article. No terminal, submission form, pending action or execution control is present.
            """, false)
        ]
        let analyzer = LocalRiskAnalyzer()
        var results: [[String: Any]] = []
        var failures = 0
        let selectedCases = CommandLine.arguments.contains("--warning-only") ? [] : cases
        for (name, text, expectsHigh) in selectedCases {
            let start = Date()
            let snapshot = ScreenSnapshot(appName: "Muse Context Fixture", windowTitle: name,
                text: text, evidence: .visibleText(text))
            let verdict = try await analyzer.analyze(snapshot: snapshot, model: LocalModelConfiguration.model,
                directAnswer: true, scope: .desktop)
            let passed = expectsHigh ? verdict.riskLevel == .high : [.safe, .low].contains(verdict.riskLevel)
            if !passed { failures += 1 }
            results.append(["case": name, "risk": verdict.riskLevel.rawValue, "passed": passed,
                "seconds": Date().timeIntervalSince(start), "summary": verdict.summary])
            print("\(passed ? "PASS" : "FAIL") \(name): \(verdict.riskLevel.rawValue) · \(verdict.summary)")
            fflush(stdout)
        }
        let report = RiskReportChatContext(sourceLabel: "Earlier desktop warning", appName: "Muse Context Fixture",
            windowTitle: "Harbor wallet recovery", riskLevel: .high,
            summary: "A third-party agent requested the entire 12-word wallet seed phrase and one-time code on a different recovery domain.",
            guidance: "Do not share the seed phrase or code; verify support through the official account site.", categories: ["credential_theft"])
        let explanation = try await analyzer.answerQuestion("Why should I stop?", context: report,
            model: LocalModelConfiguration.model, directAnswer: true)
        let lower = explanation.lowercased()
        let explained = lower.contains("seed") && !lower.contains("untrusted") &&
            (lower.contains("warning") || lower.contains("earlier") || lower.contains("report"))
        if !explained { failures += 1 }
        results.append(["case": "explain earlier warning without fresh screen", "passed": explained, "answer": explanation])
        print("\(explained ? "PASS" : "FAIL") explain earlier warning: \(explanation)")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "build/desktop-risk-model-results.json"))
        if failures > 0 { exit(1) }
    }
}
