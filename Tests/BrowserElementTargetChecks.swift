import AppKit
import Foundation

@main struct BrowserElementTargetChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String = "") { precondition(condition, message) }
        let now = 2_000_000_000_000.0
        func wire(rect: [String: Double] = ["x":100,"y":200,"width":160,"height":40],
                  dpr: Double = 2, zoom: Double = 1, left: Double = 100, top: Double = 100,
                  pointer: [String: Double]? = nil) -> [String: Any] {
            var object: [String: Any] = ["version":1,"document_id":"document-123","revision":7,"measured_at":now,
                "rect":rect,"viewport":["width":1000.0,"height":700.0,"scroll_x":0.0,"scroll_y":0.0,
                    "device_pixel_ratio":dpr,"visual_scale":1.0,"offset_x":0.0,"offset_y":0.0],
                "browser_window":["id":4,"tab_id":3,"left":left,"top":top,"width":1000*zoom,"height":700*zoom+100,"zoom":zoom]]
            if let pointer { object["pointer"] = pointer }
            return object
        }
        func decode(_ object: [String: Any]) throws -> BrowserElementTarget {
            try JSONDecoder().decode(BrowserElementTarget.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func context(window: CGRect = CGRect(x:100,y:100,width:1000,height:800),
                     time: Double = now, document: String = "document-123", revision: Int = 7,
                     tab: Int = 3, browser: Int = 4, screens: [CGRect] = []) -> BrowserElementTarget.Context {
            .init(documentID: document, revision: revision, tabID: tab, browserWindowID: browser,
                windowBounds: window, primaryScreenTop: 1080, nowMS: time, screens: screens)
        }
        let standard = try decode(wire())
        let viewport = CGRect(x:100,y:200,width:1000,height:700)
        let target = standard.resolve(context: context(), trustedViewportBounds: viewport)!
        check(target.elementRect == CGRect(x:200,y:640,width:160,height:40))
        check(target.point == CGPoint(x:280,y:660) && target.basis == .accessibility)
        check(try decode(wire(dpr:4)).resolve(context:context(),trustedViewportBounds:viewport)?.point == target.point,
            "Retina DPR must not double the logical desktop coordinates.")

        let zoomed = try decode(wire(dpr:2.5,zoom:1.25))
        let zoomWindow = CGRect(x:100,y:100,width:1250,height:975)
        let zoomViewport = CGRect(x:100,y:200,width:1250,height:875)
        let zoomTarget = zoomed.resolve(context:context(window:zoomWindow),trustedViewportBounds:zoomViewport)!
        check(zoomTarget.elementRect == CGRect(x:225,y:580,width:200,height:50))
        check(zoomTarget.point == CGPoint(x:325,y:605), "Page zoom uses Chrome's trusted zoom factor exactly once.")

        let external = try decode(wire(left:-1500,top:-600))
        let externalWindow = CGRect(x:-1500,y:-600,width:1000,height:800)
        let externalViewport = CGRect(x:-1500,y:-500,width:1000,height:700)
        let externalTarget = external.resolve(context:context(window:externalWindow,
            screens:[CGRect(x:-1600,y:1080,width:1600,height:900)]),trustedViewportBounds:externalViewport)!
        check(externalTarget.point == CGPoint(x:-1320,y:1360), "Negative-X and displays above primary retain their coordinate spaces.")
        check(external.resolve(context:context(window:externalWindow,screens:[CGRect(x:0,y:0,width:1920,height:1080)]),
            trustedViewportBounds:externalViewport) == nil, "A point outside current screens is never presented as precise.")

        let pointer = ["client_x":120.0,"client_y":220.0,"screen_x":220.0,"screen_y":420.0,"captured_at":now]
        let calibrated = try decode(wire(pointer:pointer))
        check(calibrated.resolve(context:context())?.point == target.point)
        check(calibrated.resolve(context:context())?.basis == .trustedPointer)
        check(standard.resolve(context:context()) == nil, "No inferred browser titlebar offset is a substitute for a trusted viewport origin.")
        var badPointer = pointer;badPointer["screen_x"] = 90000
        check(try decode(wire(pointer:badPointer)).resolve(context:context()) == nil)
        badPointer = pointer;badPointer["captured_at"] = now-12001
        check(try decode(wire(pointer:badPointer)).resolve(context:context()) == nil)
        badPointer = pointer;badPointer["screen_x"] = 320
        check(try decode(wire(pointer:badPointer)).resolve(context:context()) == nil,
            "A calibrated viewport must fit inside the verified native Chrome window.")

        for invalid in [context(time:now+2501),context(time:now-251),context(document:"different"),
                        context(revision:8),context(tab:99),context(browser:99),
                        context(window:CGRect(x:500,y:100,width:1000,height:800))] {
            check(standard.resolve(context:invalid,trustedViewportBounds:viewport) == nil)
        }
        var malformed = wire()
        malformed["viewport"] = ["width":1000.0,"height":700.0,"scroll_x":0.0,"scroll_y":0.0,
            "device_pixel_ratio":2.0,"visual_scale":2.0,"offset_x":0.0,"offset_y":0.0]
        check(try decode(malformed).resolve(context:context(),trustedViewportBounds:viewport) == nil)
        check(try decode(wire(rect:["x":990,"y":200,"width":160,"height":40])).resolve(context:context(),trustedViewportBounds:viewport) == nil)
        let encoded = try JSONEncoder().encode(standard)
        check(try JSONDecoder().decode(BrowserElementTarget.self,from:encoded) == standard)
        print("PASS: exact element targeting validates source/freshness/native window, handles Retina/page zoom/multi-display, and refuses stale/offscreen/uncalibrated coordinates")
    }
}
