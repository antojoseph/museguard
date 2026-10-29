import AppKit

enum MuseLayout {
    static let chatContentSize = CGSize(width:336,height:296)
    static let chatPanelSize = CGSize(width:356,height:316)
    static let characterSize: CGFloat = 220
    static let panelSize = CGSize(width: 220, height: 220)
    static let characterRect = CGRect(origin: .zero, size: panelSize)
    // Conservative visible silhouette, excluding the transparent render padding.
    // Includes head motion and raised hands; this—not the bubble—meets the edge.
    static let visibleCharacter = CGRect(x: 40, y: 30, width: 140, height: 148)
}

struct GuardianPlacement {
    /// Reserve the complete rendered silhouette, including extended hands.
    static let messageGutter: CGFloat = 24
    let origin: CGPoint
    let character = MuseLayout.characterRect
    var visibleRect: CGRect { MuseLayout.visibleCharacter.offsetBy(dx: origin.x, dy: origin.y) }
    var anchor: CGPoint { CGPoint(x: origin.x + 110, y: origin.y + 110) }

    init(anchor requested: CGPoint, screen: CGRect) {
        let body = MuseLayout.visibleCharacter
        let safe = screen.insetBy(dx: 6, dy: 6)
        origin = CGPoint(x: min(max(requested.x - 110, safe.minX - body.minX), safe.maxX - body.maxX),
                         y: min(max(requested.y - 110, safe.minY - body.minY), safe.maxY - body.maxY))
    }
    static func nearestScreen(to point: CGPoint, screens: [CGRect]) -> CGRect? {
        screens.min { distance(point, to: $0) < distance(point, to: $1) }
    }
    private static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
    static func boundedMessageSize(_ size: CGSize, screen: CGRect) -> CGSize {
        let safe = messageSafeScreen(screen)
        return CGSize(width:max(1,min(size.width,safe.width)),height:max(1,min(size.height,safe.height)))
    }
    static func messageFrame(size requested: CGSize, avatar: CGRect, screen: CGRect, obstacles: [CGRect], pointer: CGPoint, preferSide: Bool = false) -> CGRect {
        let size = boundedMessageSize(requested,screen:screen), safe = messageSafeScreen(screen)
        enum Side { case above, below, right, left }
        struct Slot {
            let side: Side
            let bounds: CGRect
            var isSide: Bool { side == .left || side == .right }
        }
        // Build free regions first. Clamping a proposed bubble after placing it
        // is unsafe: an edge clamp can push it back through the character.
        let slots = [
            Slot(side:.above,bounds:CGRect(x:safe.minX,y:max(safe.minY,avatar.maxY+messageGutter),width:safe.width,height:max(0,safe.maxY-max(safe.minY,avatar.maxY+messageGutter)))),
            Slot(side:.below,bounds:CGRect(x:safe.minX,y:safe.minY,width:safe.width,height:max(0,min(safe.maxY,avatar.minY-messageGutter)-safe.minY))),
            Slot(side:.right,bounds:CGRect(x:max(safe.minX,avatar.maxX+messageGutter),y:safe.minY,width:max(0,safe.maxX-max(safe.minX,avatar.maxX+messageGutter)),height:safe.height)),
            Slot(side:.left,bounds:CGRect(x:safe.minX,y:safe.minY,width:max(0,min(safe.maxX,avatar.minX-messageGutter)-safe.minX),height:safe.height))
        ]
        func frame(in slot: Slot, size: CGSize) -> CGRect {
            let x: CGFloat, y: CGFloat
            switch slot.side {
            case .above, .below:
                x = min(max(avatar.midX-size.width/2,slot.bounds.minX),slot.bounds.maxX-size.width)
                y = slot.side == .above ? slot.bounds.minY : slot.bounds.maxY-size.height
            case .right, .left:
                x = slot.side == .right ? slot.bounds.minX : slot.bounds.maxX-size.width
                y = min(max(avatar.midY-size.height/2,slot.bounds.minY),slot.bounds.maxY-size.height)
            }
            return CGRect(x:x,y:y,width:size.width,height:size.height)
        }
        func cost(_ frame: CGRect) -> CGFloat {
            let area = max(1, frame.width*frame.height)
            // A warning must remain still while the user moves toward Got it.
            return obstacles.reduce(0) { $0 + overlap(frame,$1)/area }
                + (!preferSide && frame.contains(pointer) ? 4 : 0)
        }
        let full = slots.filter { $0.bounds.width >= size.width && $0.bounds.height >= size.height }
        if !full.isEmpty {
            let sideSlots = full.filter(\.isSide)
            let choices = preferSide && !sideSlots.isEmpty ? sideSlots : full
            return choices.map { frame(in:$0,size:size) }.min { cost($0) < cost($1) }!
        }
        // On a small display, retain the largest adjacent portion of the
        // message instead of covering Muse. Keep the same 24-point exclusion.
        let reduced = slots.filter { $0.bounds.width >= 1 && $0.bounds.height >= 1 }.map { slot in
            (slot,frame(in:slot,size:CGSize(width:min(size.width,slot.bounds.width),height:min(size.height,slot.bounds.height))))
        }
        // Preserve readable line width above/below before narrowing a warning
        // into a side strip. The caller can scroll the available message height.
        let fullWidthVertical = reduced.filter { !$0.0.isSide && $0.1.width == size.width }
        let reducedChoices = preferSide && !fullWidthVertical.isEmpty ? fullWidthVertical : reduced
        if let best = reducedChoices.min(by: { a,b in
            let areaA = a.1.width*a.1.height, areaB = b.1.width*b.1.height
            if areaA != areaB { return areaA > areaB }
            if preferSide && a.0.isSide != b.0.isSide { return a.0.isSide }
            return cost(a.1) < cost(b.1)
        }) { return best.1 }
        // If the silhouette plus gutter covers the entire viewport, separation
        // is physically impossible. Stay on-screen and minimize body overlap.
        let corners = [CGPoint(x:safe.minX,y:safe.minY),CGPoint(x:safe.maxX-size.width,y:safe.minY),
                       CGPoint(x:safe.minX,y:safe.maxY-size.height),CGPoint(x:safe.maxX-size.width,y:safe.maxY-size.height)]
        return corners.map { CGRect(origin:$0,size:size) }.min {
            let a = overlap($0,avatar), b = overlap($1,avatar)
            return a == b ? cost($0) < cost($1) : a < b
        }!
    }
    private static func messageSafeScreen(_ screen: CGRect) -> CGRect {
        screen.insetBy(dx:min(6,max(0,(screen.width-1)/2)),dy:min(6,max(0,(screen.height-1)/2)))
    }
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width*r.height
    }
}

/// Deterministic geometry policy: prefer exposed edges, then avoid recently
/// used pointer areas. A margin prevents small changes from causing oscillation.
enum GuardianAutoPlacement {
    static func destination(current: CGPoint, screen: CGRect, obstacles: [CGRect], recentPointers: [CGPoint]) -> CGPoint? {
        let positions = [CGPoint(x:screen.minX,y:screen.minY), CGPoint(x:screen.maxX,y:screen.minY),
                         CGPoint(x:screen.minX,y:screen.maxY), CGPoint(x:screen.maxX,y:screen.maxY),
                         CGPoint(x:screen.minX,y:screen.midY), CGPoint(x:screen.maxX,y:screen.midY),
                         CGPoint(x:screen.midX,y:screen.minY), CGPoint(x:screen.midX,y:screen.maxY)]
        func cost(_ point: CGPoint) -> CGFloat {
            let body = GuardianPlacement(anchor: point, screen: screen).visibleRect
            let area = body.width * body.height
            let overlap = obstacles.reduce(CGFloat(0)) { $0 + GuardianPlacement.overlap(body,$1)/area }
            let pointer = recentPointers.reduce(CGFloat(0)) { value, p in
                let zone = CGRect(x:p.x-125,y:p.y-95,width:250,height:190)
                return max(value, GuardianPlacement.overlap(body,zone)/area)
            }
            let edgeDistance = min(body.minX-screen.minX, screen.maxX-body.maxX,
                                   body.minY-screen.minY, screen.maxY-body.maxY)
            return overlap*3 + pointer*6 + min(1,max(0,edgeDistance)/120)*1.2
        }
        let candidates = positions.map { GuardianPlacement(anchor:$0,screen:screen).anchor }
        guard let best = candidates.min(by: { cost($0) < cost($1) }), cost(current)-cost(best) > 0.65,
              hypot(best.x-current.x,best.y-current.y) > 80 else { return nil }
        return best
    }
}

/// Reserve the whole bed/settling envelope and select once per nap. A sleeping
/// companion stays put rather than chasing changing pointer samples.
enum GuardianSleepPlacement {
    static let footprint = CGRect(x:28,y:20,width:164,height:174)
    static func destination(current:CGPoint,screen:CGRect,obstacles:[CGRect],recentPointers:[CGPoint]) -> CGPoint {
        let r=footprint, margin:CGFloat=10
        let xs=[screen.minX+margin-r.minX,screen.maxX-margin-r.maxX]
        let ys=[screen.minY+margin-r.minY,screen.maxY-margin-r.maxY]
        let candidates=xs.flatMap { x in ys.map { y in CGPoint(x:x+110,y:y+110) } }
        func cost(_ p:CGPoint)->CGFloat {
            let bed=r.offsetBy(dx:p.x-110,dy:p.y-110),area=r.width*r.height
            let busy=obstacles.reduce(CGFloat(0)) { $0+GuardianPlacement.overlap(bed,$1)/area }
            let pointer=recentPointers.reduce(CGFloat(0)) { result,point in
                max(result,GuardianPlacement.overlap(bed,CGRect(x:point.x-150,y:point.y-120,width:300,height:240))/area)
            }
            return busy*4+pointer*8+hypot(p.x-current.x,p.y-current.y)*0.0001
        }
        return candidates.min { cost($0)<cost($1) } ?? current
    }
}

/// Bounds only; no screenshot, page text, keystrokes, or new permission prompt.
@MainActor
enum GuardianActivityGeometry {
    static func activeWindowBounds() -> [CGRect] {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String:Any],
                  let r = CGRect(dictionaryRepresentation:bounds as CFDictionary), r.width>80, r.height>80 else { return nil }
            return CGRect(x:r.minX,y:top-r.maxY,width:r.width,height:r.height)
        }
    }
}

/// Keep feet on a level walk, then climb the edge to a higher sleeping corner.
struct GuardianTravelLeg {
    let from: CGPoint
    let to: CGPoint
    let animation: String
    var duration: Double { max(1, hypot(to.x-from.x,to.y-from.y)/(animation == "climb" ? 75 : 110)) }
}
enum GuardianBedtimeRoute {
    static func legs(from:CGPoint,to:CGPoint) -> [GuardianTravelLeg] {
        if to.y-from.y>100 {
            let edge=CGPoint(x:to.x,y:from.y)
            var route:[GuardianTravelLeg]=[]
            if abs(edge.x-from.x)>12 { route.append(GuardianTravelLeg(from:from,to:edge,animation:"walk")) }
            route.append(GuardianTravelLeg(from:edge,to:to,animation:"climb"))
            return route
        }
        return hypot(to.x-from.x,to.y-from.y)>12 ? [GuardianTravelLeg(from:from,to:to,animation:"walk")] : []
    }
}
