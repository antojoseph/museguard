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
        print("PASS: frame protocol, truncation rejection, Retina tile geometry, jump timing, idle policy")
    }
}
