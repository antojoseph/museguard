import Foundation

/// Opt-in behavioral checks against the real local model. Evidence is synthetic
/// or sanitized; none of the described links is followed and no UI is driven.
@main struct BrowserRiskModelChecks {
    private struct Scenario {
        let name: String
        let page: BrowserRequest.Page
        let expectsAlert: Bool
    }

    @MainActor static func main() async throws {
        let screenshotText = """
        Why is this message in spam? This message is similar to messages that were identified as spam in the past.
        Translated: Japanese → English. Translate can make mistakes, so verify translations.
        Thank you very much for contacting us through the Example International website.
        We will contact you shortly after reviewing your message. Please wait a moment.
        The information you entered is shown below.
        Name: Good afternoon user! You got +110475 dollars. Funds transfer initiated: Verify your request. Continue --- payout-verify.example.test/claim
        Visible link destinations: payout-verify.example.test/claim → https://payout-verify.example.test/claim
        Visible forms:
        """
        let mainText = "Automatic reply: Thank you for contacting us Why is this message in spam? This message is similar to messages that were identified as spam in the past. Thank you for contacting us through the Example International website. We will contact you shortly after reviewing your message. The information you entered is shown below. Name: Good afternoon! You got +110475 dollars. Funds transfer initiated: Verify your request. Continue — payout-verify.example.test/verify Inquiry details: Verify this unexpected funds transfer using the external link above."
        let navigation = Array(repeating: "Mailbox folder navigation", count: 250).joined(separator: " ")
        let localText = String((mainText + " Inbox " + navigation).prefix(3500)) +
            " Visible link destinations: payout-verify.example.test/verify → https://payout-verify.example.test/verify Visible forms:"
        let cases = [
            Scenario(name: "unsolicited payout embedded in Gmail auto-reply",
                page: .init(url: "https://mail.google.com/mail/u/1/", title: "Automatic reply: Thank you for contacting us - Gmail", text: screenshotText),
                expectsAlert: true),
            Scenario(name: "local inbox simulation with busy navigation",
                page: .init(url: "http://127.0.0.1:8768/index.html", title: "Muse proactive inbox test", text: localText),
                expectsAlert: true),
            Scenario(name: "unauthenticated signature request with stripped links",
                page: .init(url: "https://mail.google.com/mail/u/1/", title: "Finish by adding your signature.", text: """
                DocuSign: Sign Document <signing-security@unverified.example.test>
                To: reader@example.test
                Be careful with this message. This message isn't authenticated and sender can't be verified. Use caution when clicking links, downloading attachments or replying with personal info.
                docusign. Please review your document. You have a shared document to review. Please add your signature. It only takes 2 minutes. Expires November 1, 2026.
                Review Document
                Printed message text: https://document.docusign.com
                This message was sent by DocuSign. Do not share this email. For questions about the document, contact the sender.
                Visible link destinations: Learn more → https://support.google.com/mail/answer/180707
                Visible forms:
                """), expectsAlert: true),
            Scenario(name: "ordinary expected signature request",
                page: .init(url: "https://mail.google.com/mail/u/1/", title: "Please sign: Harbor consulting agreement", text: """
                DocuSign <dse@docusign.net>
                To: reader@example.test
                Harbor Consulting sent you an agreement to review and sign, as discussed in your meeting.
                Review Document
                Visible link destinations: Review Document → https://account.docusign.com/signing
                This message was sent by DocuSign. Do not share this email. For questions about the document, contact the sender.
                """), expectsAlert: false),
            Scenario(name: "ordinary auto-reply with external support link",
                page: .init(url: "https://mail.google.com/mail/u/1/", title: "Contact confirmation - Gmail", text: """
                Thank you for contacting Example International. We received your question about business hours and will reply soon. No payment, verification or sign-in is requested.
                You can read our ordinary support guide at https://support.example.test/hours.
                Visible link destinations: Business hours → https://support.example.test/hours
                """), expectsAlert: false),
            Scenario(name: "security article quotes the same payout lure",
                page: .init(url: "https://training.example.test/phishing", title: "Recognizing email scams", text: """
                Read-only security training article. Quoted scam example: You got +110475 dollars. Funds transfer initiated: Verify your request. Continue --- payout-verify.example.test/claim.
                This example is not an offer or pending action directed at the reader. Never follow unsolicited payout verification links. This article explains how to recognize that scam.
                """), expectsAlert: false),
            Scenario(name: "spam label on an ordinary newsletter",
                page: .init(url: "https://mail.google.com/mail/u/1/", title: "Monthly garden club newsletter - Gmail", text: """
                Why is this message in spam? This message is similar to messages that were identified as spam in the past.
                Garden club October newsletter. Here are photos and planting notes from last weekend. No sign-in, payment, prize or verification is requested.
                Read the public meeting notes: https://garden-club.example.test/newsletter/october.
                Visible link destinations: Meeting notes → https://garden-club.example.test/newsletter/october
                """), expectsAlert: false),
            Scenario(name: "ordinary same-origin account sign-in",
                page: .init(url: "https://account.example.test/login", title: "Example account sign in", text: """
                Example account. Sign in to manage your account. Enter your email and password.
                Visible link destinations: Privacy → https://account.example.test/privacy
                Visible forms: Form destination: https://account.example.test/session; method: post; field types: email, password; sensitive fields: true
                """), expectsAlert: false)
        ]
        let analyzer = LocalRiskAnalyzer(scheduler: LocalInferenceScheduler())
        let coordinator = BrowserAssessmentCoordinator(analyzer: analyzer, modelReady: { true })
        var results: [[String: Any]] = []
        var failures = 0
        let selected = CommandLine.arguments.contains("--signature-only") ? cases.filter { $0.name.contains("signature") } :
            CommandLine.arguments.contains("--non-signature-only") ? cases.filter { !$0.name.contains("signature") } : cases
        for scenario in selected {
            // Repeat missed alerts while preserving the model's own medium
            // or high judgment and the corresponding presentation route.
            for repetition in 1...(scenario.expectsAlert ? 3 : 1) {
                let request = BrowserRequest(id: UUID().uuidString, type: "assess", page: scenario.page,
                    action: .init(kind: "page", url: nil, label: nil, method: "GET", sensitive: false), purpose: "proactive")
                let began = Date()
                let response = await coordinator.handle(request)
                let warnable = ["medium", "high"].contains(response.riskLevel)
                var passed = response.ok && (scenario.expectsAlert ? warnable : !warnable)
                if passed && warnable {
                    let display = await coordinator.handle(BrowserRequest(id: UUID().uuidString,
                        type: response.riskLevel == "high" ? "present-block" : "present-warning", assessmentID: request.id))
                    passed = display.ok && display.riskLevel == response.riskLevel && display.decision == response.decision
                }
                if !passed { failures += 1 }
                results.append(["case": scenario.name, "repetition": repetition, "risk": response.riskLevel,
                    "decision": response.decision, "passed": passed, "summary": response.summary,
                    "guidance": response.guidance, "seconds": Date().timeIntervalSince(began)])
                print("\(passed ? "PASS" : "FAIL") \(scenario.name) #\(repetition): \(response.riskLevel) · \(response.summary)")
                fflush(stdout)
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "build/browser-risk-model-results.json"))
        if failures > 0 { exit(1) }
    }
}
