import AppKit

@main
struct CharacterChecks {
    static func main() throws {
        func targetWindow(_ id: UInt32, pid: Int32 = 7, bounds: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let verifiedBounds = CGRect(x: -1500, y: 200, width: 600, height: 400)
        let targetCandidates = [
            targetWindow(102, bounds: CGRect(x: 20, y: 20, width: 800, height: 600)),
            targetWindow(101, pid: 8, bounds: CGRect(x: 0, y: 0, width: 900, height: 700)),
            targetWindow(101, bounds: verifiedBounds)
        ]
        assert(GuardianTarget.windowCenter(windowID: 101, processID: 7, windows: targetCandidates,
            primaryScreenTop: 1080) == CGPoint(x: -1200, y: 680),
            "Warnings target the verified capture window, not another window from the same app.")
        assert(GuardianTarget.windowCenter(windowID: 101, processID: 9, windows: targetCandidates,
            primaryScreenTop: 1080) == nil)
        assert(GuardianTarget.windowCenter(windowID: 0, processID: 7, windows: targetCandidates,
            primaryScreenTop: 1080) == nil)
        let upperDisplayWindows = [targetWindow(103, bounds: CGRect(x: 200, y: -500, width: 400, height: 400))]
        assert(GuardianTarget.windowCenter(windowID: 103, processID: 7, windows: upperDisplayWindows,
            primaryScreenTop: 1080) == CGPoint(x: 400, y: 1380),
            "Core Graphics top-down Y is converted using the primary display, including displays above it.")
        let from = CGPoint(x: -1200, y: 20), to = CGPoint(x: 500, y: 300)
        let scene = GuardianDesktopScene(viewport: CGRect(x: -1728, y: -100, width: 3456, height: 1180), from: from, to: to, fromScale: 1, toScale: 2.15)
        assert(scene.command["fromX"] as? CGFloat == 528)
        assert(scene.command["fromY"] as? CGFloat == 120)
        assert(scene.reversed.from == to && scene.reversed.to == from)
        assert(scene.reversed.fromScale == 2.15 && scene.reversed.toScale == 1)
        assert(scene.reversed.reversed.viewport == scene.viewport)
        assert(GuardianJumpTiming.direction(from: from, to: to) == 1)
        assert(GuardianJumpTiming.direction(from: to, to: from) == -1)
        assert(GuardianJumpTiming.direction(from: from, to: from) == 0)
        assert(GuardianJumpTiming.duration(for: "jump") == GuardianJumpTiming.duration(for: "return"))
        assert(GuardianJumpTiming.anticipation > 0.3 && GuardianJumpTiming.landing > 0.3)
        // The visible body reaches each edge even when transparent canvas
        // extends off-screen. Independent bubbles fit without pushing Muse.
        for screen in [CGRect(x: 0, y: 0, width: 1728, height: 1080), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for x in [screen.minX - 100, screen.midX, screen.maxX + 100] {
                for y in [screen.minY - 100, screen.midY, screen.maxY + 100] {
                    let p = GuardianPlacement(anchor: CGPoint(x: x, y: y), screen: screen)
                    assert(screen.contains(p.visibleRect))
                    for size in [CGSize(width:240,height:70),CGSize(width:380,height:336)] {
                        let message = GuardianPlacement.messageFrame(size:size,avatar:p.visibleRect,screen:screen,obstacles:[],pointer:.zero)
                        assert(screen.contains(message))
                        assert(GuardianPlacement.overlap(message,p.visibleRect) == 0)
                    }
                    let again = GuardianPlacement(anchor: p.anchor, screen: screen)
                    assert(again.anchor == p.anchor && again.origin == p.origin)
                }
            }
        }
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        assert(GuardianPlacement.nearestScreen(to: CGPoint(x: -1500, y: 500), screens: [right,left]) == left)
        assert(GuardianPlacement.nearestScreen(to: CGPoint(x: 200, y: 500), screens: [left,right]) == right)
        assert(GuardianPlacement.nearestScreen(to: .zero, screens: []) == nil)
        // The complete chat panel, including its close button and shadow
        // padding, must fit every corner and displays with negative origins.
        for screen in [right,left,CGRect(x:0,y:0,width:640,height:480)] {
            for x in [screen.minX,screen.maxX] { for y in [screen.minY,screen.maxY] {
                let avatar=GuardianPlacement(anchor:CGPoint(x:x,y:y),screen:screen).visibleRect
                let panel=GuardianPlacement.messageFrame(size:MuseLayout.chatPanelSize,avatar:avatar,screen:screen,obstacles:[],pointer:CGPoint(x:x,y:y))
                assert(screen.insetBy(dx:6,dy:6).contains(panel))
                assert(panel.size == GuardianPlacement.boundedMessageSize(MuseLayout.chatPanelSize,screen:screen))
                let close=CGRect(x:panel.maxX-50,y:panel.maxY-48,width:28,height:28)
                assert(screen.contains(close))
            } }
        }
        // Warning cards reserve the full renderer silhouette, including hands,
        // rather than a small nominal face/body rectangle. A side card stays
        // still while the pointer approaches its acknowledgement button.
        func separated(_ panel: CGRect, from avatar: CGRect) -> Bool {
            let gap = max(panel.minX-avatar.maxX,avatar.minX-panel.maxX,
                          panel.minY-avatar.maxY,avatar.minY-panel.maxY)
            return gap >= GuardianPlacement.messageGutter-0.0001
        }
        let warningSize = CGSize(width:380,height:320)
        let centerBody = CGRect(x:744,y:390,width:240,height:280)
        let centered = GuardianPlacement.messageFrame(size:warningSize,avatar:centerBody,screen:right,
            obstacles:[],pointer:.zero,preferSide:true)
        assert(centered.minX == centerBody.maxX+24 && centered.size == warningSize,
            "A centered warning prefers the right side with a full body gutter.")
        assert(separated(centered,from:centerBody) && right.insetBy(dx:6,dy:6).contains(centered))
        for pointer in [centered.origin,CGPoint(x:centered.midX,y:centered.midY),
                        CGPoint(x:centerBody.midX,y:centerBody.midY),CGPoint(x:right.maxX,y:right.maxY)] {
            assert(GuardianPlacement.messageFrame(size:warningSize,avatar:centerBody,screen:right,
                obstacles:[],pointer:pointer,preferSide:true) == centered,
                "A warning must not move away from the pointer or acknowledgement click.")
        }
        let busyRight = GuardianPlacement.messageFrame(size:warningSize,avatar:centerBody,screen:right,
            obstacles:[centered],pointer:.zero,preferSide:true)
        assert(busyRight.maxX == centerBody.minX-24 && separated(busyRight,from:centerBody))
        // User-activity/pointer costs can choose among free regions, but can
        // never make an overlapping candidate preferable to an unobscured one.
        let crowded = GuardianPlacement.messageFrame(size:warningSize,avatar:centerBody,screen:right,
            obstacles:[right],pointer:CGPoint(x:centered.midX,y:centered.midY),preferSide:true)
        assert(separated(crowded,from:centerBody) && crowded == centered)
        for screen in [right,left,CGRect(x:-1200,y:-900,width:1728,height:1080)] {
            for x in [screen.minX+6,screen.midX-120,screen.maxX-246] {
                for y in [screen.minY+6,screen.midY-140,screen.maxY-286] {
                    let fullBody=CGRect(x:x,y:y,width:240,height:280)
                    for size in [warningSize,CGSize(width:380,height:900)] {
                        let card=GuardianPlacement.messageFrame(size:size,avatar:fullBody,screen:screen,
                            obstacles:[screen],pointer:CGPoint(x:x,y:y),preferSide:true)
                        assert(screen.insetBy(dx:6,dy:6).contains(card))
                        assert(separated(card,from:fullBody),"Edges and negative monitor coordinates preserve the body gutter.")
                        assert(card.size == GuardianPlacement.boundedMessageSize(size,screen:screen))
                    }
                }
            }
        }
        // If a side card cannot fit but a complete card fits above, preserve
        // the whole card before falling back to a shortened message region.
        let narrow = CGRect(x:-320,y:-100,width:640,height:700)
        let narrowBody = CGRect(x:-120,y:-70,width:240,height:280)
        let above = GuardianPlacement.messageFrame(size:warningSize,avatar:narrowBody,screen:narrow,
            obstacles:[],pointer:.zero,preferSide:true)
        assert(above.size == warningSize && above.minY == narrowBody.maxY+24)
        assert(narrow.insetBy(dx:6,dy:6).contains(above) && separated(above,from:narrowBody))
        for screen in [CGRect(x:0,y:0,width:640,height:480),CGRect(x:-640,y:-480,width:640,height:480),
                       CGRect(x:-200,y:-100,width:320,height:240)] {
            let bodySize = screen.width < 400 ? CGSize(width:100,height:100) : CGSize(width:260,height:260)
            let body = CGRect(x:screen.midX-bodySize.width/2,y:screen.midY-bodySize.height/2,width:bodySize.width,height:bodySize.height)
            let fallback = GuardianPlacement.messageFrame(size:warningSize,avatar:body,screen:screen,
                obstacles:[screen],pointer:.zero,preferSide:true)
            assert(screen.insetBy(dx:6,dy:6).contains(fallback) && separated(fallback,from:body))
            assert(fallback.width == GuardianPlacement.boundedMessageSize(warningSize,screen:screen).width)
            assert(fallback.height > 0 && fallback.height < warningSize.height,
                "A small viewport uses the available height above/below without covering the body.")
            assert(GuardianPlacement.messageFrame(size:warningSize,avatar:body,screen:screen,
                obstacles:[screen],pointer:CGPoint(x:fallback.midX,y:fallback.midY),preferSide:true) == fallback)
        }
        let tinyScreen = CGRect(x:-80,y:-60,width:80,height:60)
        let impossible = GuardianPlacement.messageFrame(size:warningSize,avatar:tinyScreen,screen:tinyScreen,
            obstacles:[],pointer:.zero,preferSide:true)
        assert(tinyScreen.contains(impossible) && impossible.width > 0 && impossible.height > 0,
            "When the avatar fills the entire viewport, the deterministic fallback must still remain on-screen.")
        let corner = GuardianPlacement(anchor:.zero,screen:right)
        assert(corner.origin.x < 0 && corner.origin.y < 0)
        assert(corner.visibleRect.minX == 6 && corner.visibleRect.minY == 6)
        assert(GuardianAutoPlacement.destination(current:corner.anchor,screen:right,obstacles:[],recentPointers:[]) == nil)
        let leftWindow = CGRect(x:0,y:0,width:1200,height:1080)
        let safer = GuardianAutoPlacement.destination(current:corner.anchor,screen:right,obstacles:[leftWindow],recentPointers:[])!
        assert(GuardianPlacement(anchor:safer,screen:right).visibleRect.minX > leftWindow.maxX)
        let fullScreen = GuardianAutoPlacement.destination(current:CGPoint(x:864,y:540),screen:right,obstacles:[right],recentPointers:[])!
        let edge = GuardianPlacement(anchor:fullScreen,screen:right).visibleRect
        assert(min(edge.minX-right.minX,right.maxX-edge.maxX,edge.minY-right.minY,right.maxY-edge.maxY) == 6)
        let dodged = GuardianAutoPlacement.destination(current:corner.anchor,screen:right,obstacles:[right],recentPointers:[corner.anchor])!
        assert(hypot(dodged.x-corner.anchor.x,dodged.y-corner.anchor.y)>250)
        let bedCorner=GuardianSleepPlacement.destination(current:CGPoint(x:864,y:540),screen:right,obstacles:[CGRect(x:0,y:0,width:1300,height:1080)],recentPointers:[CGPoint(x:1650,y:1000)])
        let bedRect=GuardianSleepPlacement.footprint.offsetBy(dx:bedCorner.x-110,dy:bedCorner.y-110)
        assert(right.contains(bedRect) && bedRect.minX>1300 && bedRect.midY<540)
        let negativeNap=GuardianSleepPlacement.destination(current:CGPoint(x:-1500,y:400),screen:left,obstacles:[left],recentPointers:[CGPoint(x:-1800,y:100)])
        assert(left.contains(GuardianSleepPlacement.footprint.offsetBy(dx:negativeNap.x-110,dy:negativeNap.y-110)))
        let climb=GuardianBedtimeRoute.legs(from:CGPoint(x:92,y:150),to:CGPoint(x:92,y:990))
        assert(climb.count == 1 && climb[0].animation == "climb")
        let across=GuardianBedtimeRoute.legs(from:CGPoint(x:92,y:150),to:CGPoint(x:1636,y:990))
        assert(across.count == 2 && across[0].animation == "walk" && across[1].animation == "climb")
        assert(across[0].from.y == across[0].to.y && across[0].to == across[1].from)
        assert(GuardianBedtimeRoute.legs(from:.zero,to:.zero).isEmpty)
        assert(GuardianIdlePolicy.pose(after:0) == "idle")
        assert(GuardianIdlePolicy.pose(after:27.9) == "idle")
        assert(GuardianIdlePolicy.pose(after:28) == "drowsy")
        assert(GuardianIdlePolicy.pose(after:54.9) == "drowsy")
        assert(GuardianIdlePolicy.pose(after:55) == "sleep")
        assert(GuardianIdlePolicy.pose(after:3600) == "sleep")
        assert(CharacterFrame.decode(Data()) == nil)
        func frame(_ header: [UInt32], _ bytes: [UInt8]) -> Data {
            var result = Data()
            for value in header { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
            result.append(contentsOf: bytes)
            return result
        }
        let valid = frame([0x4D555345, 1, 2, 1, 42, 0], [255,0,0,255,0,0,0,0])
        let decoded = CharacterFrame.decode(valid)!
        assert(decoded.sequence == 42 && decoded.image.width == 2 && decoded.image.height == 1)
        assert(!decoded.isDesktopScene && !decoded.isSleeping)
        assert(decoded.silhouette(in:CGRect(x:-320,y:100,width:220,height:220)) == CGRect(x:-320,y:100,width:110,height:220))
        let asymmetric = CharacterFrame.decode(frame([0x4D555345,1,2,2,43,0], [0,0,0,0,0,0,0,255,0,0,0,0,0,0,0,0]))!
        assert(asymmetric.silhouette(in:CGRect(x:-320,y:100,width:320,height:320)) == CGRect(x:-160,y:260,width:160,height:160),
            "Image rows must flip into screen Y-up coordinates, including negative display origins.")
        let sleeping = frame([0x4D555345, 1, 2, 1, 44, 2], [UInt8](repeating: 0, count: 8))
        assert(CharacterFrame.decode(sleeping)?.isSleeping == true)
        assert(CharacterFrame.decode(sleeping)?.silhouette == nil)
        assert(CharacterFrame.decode(sleeping)?.isDesktopScene == false)
        let wide = frame([0x4D555345, 1, 4, 2, 43, 1], [UInt8](repeating: 0, count: 32))
        assert(CharacterFrame.decode(wide)?.isDesktopScene == true)
        assert(CharacterFrame.decode(wide)?.image.width == 4)
        func crop(_ values: [Float], flags: UInt32 = 1) -> Data {
            var bytes = frame([0x4D555345, 2, 2, 1, 45, flags], [])
            for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { bytes.append(contentsOf:$0) } }
            bytes.append(contentsOf:[UInt8](repeating:0,count:8))
            return bytes
        }
        let cropped = CharacterFrame.decode(crop([-20.5,100,320,320]))!
        assert(cropped.desktopRect == CGRect(x:-20.5,y:100,width:320,height:320))
        assert(cropped.isDesktopScene && cropped.image.width == 2)
        assert(CharacterFrame.decode(crop([0,0,320,320],flags:0)) == nil)
        assert(CharacterFrame.decode(crop([.nan,0,320,320])) == nil)
        assert(CharacterFrame.decode(crop([0,0,-1,320])) == nil)
        assert(CharacterFrame.decode(crop([0,0,320,320]).dropLast()) == nil)
        assert(CharacterFrame.decode(valid.dropLast()) == nil)
        assert(CharacterFrame.decode(frame([0x4D555345,1,UInt32.max,2,0,0],[])) == nil)
        assert(CharacterFrame.decode(frame([0x4D555345,2,2,1,0,0],[UInt8](repeating:0,count:8))) == nil)
        if CommandLine.arguments.count == 3 {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let captured = CharacterFrame.decode(bytes) else { fatalError("Invalid renderer frame") }
            let bitmap = NSBitmapImageRep(cgImage: captured.image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("PASS: true-corner bounds, independent message sizing, window/pointer avoidance and stable placement, desktop scene anchors, reversed depth journey, jump direction/timing, negative-display coordinates, valid frame, truncated frame, oversized frame, protocol version")
    }
}
