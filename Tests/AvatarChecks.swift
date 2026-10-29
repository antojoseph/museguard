import AppKit

@main
struct AvatarChecks {
    static func main() throws {
        let scene = GuardianDesktopScene(viewport: CGRect(x: -1728, y: -100, width: 3456, height: 1180), from: CGPoint(x: -1200, y: 20), to: CGPoint(x: 500, y: 300), fromScale: 1, toScale: 1)
        assert(scene.command["fromX"] as? CGFloat == 528)
        assert(scene.command["fromY"] as? CGFloat == 120)
        assert(scene.reversed.reversed.from == scene.from)
        assert(scene.reversed.from == scene.to)
        assert(GuardianJumpTiming.duration(for: "return") == GuardianJumpTiming.flight)
        assert(GuardianJumpTiming.direction(from: scene.from, to: scene.to) == 1)
        assert(GuardianJumpTiming.direction(from: scene.to, to: scene.from) == -1)
        assert(GuardianIdlePolicy.pose(after: 27) == "idle")
        assert(GuardianIdlePolicy.pose(after: 28) == "drowsy")
        assert(GuardianIdlePolicy.pose(after: 55) == "sleep")
        var header = [UInt32(0x4D555345), 1, 1, 1, 42, 2].map(\.littleEndian)
        var bytes = header.withUnsafeBytes { Data($0) }
        bytes.append(contentsOf: [240, 200, 190, 255])
        let frame = CharacterFrame.decode(bytes)!
        assert(frame.sequence == 42 && frame.image.width == 1 && frame.isSleeping)
        assert(!frame.isDesktopScene && frame.desktopRect == nil)
        assert(CharacterFrame.decode(Data(bytes.dropLast())) == nil)
        header[0] = 0
        assert(CharacterFrame.decode(header.withUnsafeBytes { Data($0) }) == nil)
        var desktop = [UInt32(0x4D555345), 2, 1, 1, 43, 1].map(\.littleEndian).withUnsafeBytes { Data($0) }
        for coordinate: Float in [-40, 20, 320, 320] {
            var value = coordinate.bitPattern.littleEndian
            desktop.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        desktop.append(contentsOf: [240, 200, 190, 255])
        let tile = CharacterFrame.decode(desktop)!
        assert(tile.isDesktopScene && tile.desktopRect == CGRect(x: -40, y: 20, width: 320, height: 320))
        assert(CharacterFrame.decode(Data(desktop.prefix(24))) == nil)
        let screens=[CGRect(x:-1920,y:-100,width:1920,height:1080),CGRect(x:0,y:0,width:1728,height:1080)]
        let viewport=AvatarDesktopGeometry.viewport(screens:screens)
        assert(viewport==CGRect(x:-1920,y:-100,width:3648,height:1180))
        let clamped=AvatarDesktopGeometry.bounded(CGPoint(x:-3000,y:-2000),screens:screens)
        assert(clamped==CGPoint(x:-1844,y:-14))
        let home=AvatarDesktopGeometry.homeRect(anchor:clamped,viewport:viewport)
        assert(home.midX+viewport.minX==clamped.x && home.midY+viewport.minY==clamped.y)
        assert(AvatarDesktopGeometry.cropAnchor(CGRect(x:528-160,y:120-160,width:320,height:320),viewport:scene.viewport)==scene.from)
        assert(AvatarDesktopGeometry.bounded(CGPoint(x:1000,y:400),screens:screens)==CGPoint(x:1000,y:400))
        var alphaRows = [UInt32(0x4D555345),1,1,2,44,0].map(\.littleEndian).withUnsafeBytes { Data($0) }
        alphaRows.append(contentsOf:[240,200,190,255,240,200,190,0])
        let alphaImage = CharacterFrame.decode(alphaRows)!.image
        let pixelRect = CGRect(x:-100,y:30,width:10,height:20)
        assert(AvatarDesktopGeometry.hasVisiblePixel(in:alphaImage,worldRect:pixelRect,at:CGPoint(x:-95,y:45)))
        assert(!AvatarDesktopGeometry.hasVisiblePixel(in:alphaImage,worldRect:pixelRect,at:CGPoint(x:-95,y:35)))
        assert(!AvatarDesktopGeometry.hasVisiblePixel(in:alphaImage,worldRect:pixelRect,at:CGPoint(x:-115,y:45)))
        print("PASS: frame protocol, truncation rejection, Retina tile geometry, jump timing, idle policy, negative-display desktop placement and crop anchors, alpha-aware desktop click-through")
    }
}
