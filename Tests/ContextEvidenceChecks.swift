import Foundation
import CoreGraphics

@main struct ContextEvidenceChecks {
    static func main() {
        let body = "Harbor support answers customer questions on weekdays. Standard orders arrive in three business days."
        var document = AccessibilityEvidenceBuilder(maxCharacters: 8_000)
        document.visit(role: "AXStaticText", inControlRegion: false, substantialVisual: false)
        document.append(body, role: "AXStaticText", inControlRegion: false)
        document.append(body, role: "AXStaticText", inControlRegion: false)
        assert(document.text == body && document.evidence.semanticTextElements == 1)
        assert(document.evidence.semanticTextCharacters == body.count && document.evidence.hasMeaningfulText)
        assert(!document.evidence.needsVisualContext)

        var toolbar = AccessibilityEvidenceBuilder(maxCharacters: 8_000)
        for number in 0..<30 {
            toolbar.visit(role: "AXButton", inControlRegion: true, substantialVisual: false)
            toolbar.append("Toolbar control \(number) with a long descriptive label", role: "AXButton", inControlRegion: true)
        }
        assert(toolbar.text.count > 1_000 && toolbar.evidence.controlElements == 30)
        assert(!toolbar.evidence.hasMeaningfulText && toolbar.evidence.needsVisualContext,
            "Large amounts of control text are not a readable document.")
        toolbar.append(body, role: "AXStaticText", inControlRegion: true)
        assert(!toolbar.evidence.hasMeaningfulText, "Static labels inside navigation still are not document text.")

        var article = AccessibilityEvidenceBuilder(maxCharacters: 8_000)
        for suffix in ["The document describes shipping.", "Returns are accepted within thirty days.", "Support is available every weekday."] {
            article.append(body + " " + suffix, role: "AXStaticText", inControlRegion: false)
        }
        article.visit(role: "AXImage", inControlRegion: false, substantialVisual: true)
        article.visit(role: "AXImage", inControlRegion: true, substantialVisual: true)
        assert(article.evidence.visualElements == 1 && !article.evidence.needsVisualContext,
            "A logo or toolbar icon beside useful article text does not force image inference.")
        var canvas = AccessibilityEvidenceBuilder(maxCharacters: 8_000)
        canvas.visit(role: "AXGroup", inControlRegion: false, substantialVisual: true)
        canvas.append("Drawing canvas", role: "AXGroup", inControlRegion: false)
        assert(canvas.evidence.visualElements == 1 && canvas.evidence.needsVisualContext)

        var limited = AccessibilityEvidenceBuilder(maxCharacters: 32)
        limited.append("CaseSensitive TOKEN-ABC costs $15", role: "AXTextArea", inControlRegion: false)
        limited.append("another line", role: "AXTextArea", inControlRegion: false)
        assert(limited.text.count <= 32 && limited.evidence.truncated)
        assert(ContextEvidence.normalizedText(" TOKEN-ABC\n costs  $15 ") == "TOKEN-ABC costs $15")
        assert(ContextEvidence.normalizedText("TOKEN-ABC") != ContextEvidence.normalizedText("token-abc"))
        assert(!ContextEvidence.unknown.isMeasured && !ContextEvidence.unknown.hasMeaningfulText)
        assert(ContextEvidence.visibleText(body).hasMeaningfulText)
        assert(!ContextEvidence.visibleText("").hasMeaningfulText)

        let a = ScreenWindowCandidate(id: 11, title: "Guide")
        let b = ScreenWindowCandidate(id: 12, title: "Invoice")
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", candidates: [a,b]) == 11)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, candidates: [a,b]) == nil)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Missing dialog", candidates: [a]) == nil)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", candidates: [a, .init(id:13,title:"Guide")]) == nil)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, candidates: [a]) == 11)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", candidates: [.init(id:11,title:nil)]) == 11)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, candidates: [.init(id:0,title:nil)]) == nil)
        // CG dictionaries bridge integer fields as both native Swift Int and
        // NSNumber. A strict Int32 cast would silently drop valid app windows.
        assert(ScreenSourceIdentity.metadataInteger(Int(4321)) == 4321)
        assert(ScreenSourceIdentity.metadataInteger(Int32(4321)) == 4321)
        assert(ScreenSourceIdentity.metadataInteger(NSNumber(value:4321)) == 4321)
        assert(ScreenSourceIdentity.metadataInteger(NSNumber(value:1.5)) == nil)
        assert(ScreenSourceIdentity.metadataInteger("4321") == nil)
        let left = CGRect(x: -1_500, y: 40, width: 760, height: 562)
        let right = CGRect(x: 120, y: 70, width: 760, height: 562)
        let redacted = [ScreenWindowCandidate(id: 21, title: nil, bounds: left),
                        ScreenWindowCandidate(id: 22, title: nil, bounds: right)]
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, focusedBounds: left, candidates: redacted) == 21)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, candidates: redacted) == nil)
        let sameTitle = [ScreenWindowCandidate(id: 21, title: "Guide", bounds: left),
                         ScreenWindowCandidate(id: 22, title: "Guide", bounds: right)]
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", focusedBounds: right, candidates: sameTitle) == 22)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", candidates: sameTitle) == nil)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Old title", focusedBounds: left,
            candidates: [.init(id:21,title:"New title",bounds:left)]) == 21)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: "Guide", focusedBounds: left,
            candidates: [.init(id:22,title:"Guide",bounds:right)]) == nil,
            "A matching title cannot override conflicting current geometry.")
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil, focusedBounds: left,
            candidates: [.init(id:21,title:nil,bounds:left),.init(id:22,title:nil,bounds:left)]) == nil)
        assert(ScreenSourceIdentity.captureWindowID(focusedTitle: nil,
            focusedBounds: left.offsetBy(dx:1.5,dy:-1.5), candidates: redacted) == 21)
        assert(!ScreenSourceIdentity.validWindowBounds(CGRect(x:0,y:0,width:0,height:100)))
        print("PASS: semantic AX evidence, bounded text, numeric CG metadata, geometry/title correlation and unambiguous window capture")
    }
}
