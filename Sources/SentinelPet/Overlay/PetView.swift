import SwiftUI

/// The animated pet: a cute 8-bit Claude-style sparkle that gently bobs and
/// blinks while idle. When alert, it glows red.
struct PetView: View {
    var mood: PetMood

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bob = sin(t * 2.0) * 2.0
            let blinking = isBlinking(at: t)

            Canvas { gc, size in
                PetSprite.draw(in: &gc, size: size, blink: blinking)
            }
            .frame(width: PetSprite.spriteSize, height: PetSprite.spriteSize)
            .offset(y: bob)
            .shadow(color: glowColor, radius: mood == .alert ? 9 : 0)
            .frame(width: 100, height: 100)
        }
        .frame(width: 100, height: 100)
    }

    /// Blink for a brief moment roughly every few seconds.
    private func isBlinking(at t: TimeInterval) -> Bool {
        t.truncatingRemainder(dividingBy: 3.6) < 0.12
    }

    private var glowColor: Color {
        switch mood {
        case .alert:    return .red.opacity(0.75)
        case .scanning: return .blue.opacity(0.5)
        case .idle:     return .clear
        }
    }
}

/// Draws the pixel-art Claude mascot — a four-pointed sparkle (an astroid
/// shape) with a cute face — onto a `GraphicsContext`. The whole sprite is
/// generated procedurally so no image assets are required.
enum PetSprite {
    static let grid = 15
    static let cell: CGFloat = 6
    static var spriteSize: CGFloat { CGFloat(grid) * cell }

    // Palette (Anthropic "Claude" coral family).
    private static let orange    = Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let outline   = Color(red: 0.659, green: 0.294, blue: 0.184)
    private static let highlight = Color(red: 0.910, green: 0.604, blue: 0.494)
    private static let blush     = Color(red: 0.949, green: 0.655, blue: 0.627)
    private static let ink       = Color(red: 0.227, green: 0.165, blue: 0.133)

    static func draw(in gc: inout GraphicsContext, size: CGSize, blink: Bool) {
        let pixels = bodyPixels()
        for y in 0..<grid {
            for x in 0..<grid {
                if let color = pixels[y][x] {
                    paint(&gc, x, y, color)
                }
            }
        }
        drawFace(&gc, blink: blink)
    }

    // MARK: - Body

    /// Whether the cell (x, y) is inside the four-pointed star. Uses an astroid:
    /// sqrt(|dx|) + sqrt(|dy|) <= sqrt(R), which yields concave "sparkle" points.
    private static func isBody(_ x: Int, _ y: Int) -> Bool {
        let c = Double(grid - 1) / 2.0
        let dx = abs(Double(x) - c)
        let dy = abs(Double(y) - c)
        return dx.squareRoot() + dy.squareRoot() <= 7.0.squareRoot()
    }

    private static func bodyPixels() -> [[Color?]] {
        var g = [[Color?]](repeating: [Color?](repeating: nil, count: grid), count: grid)

        // Fill the star body.
        for y in 0..<grid {
            for x in 0..<grid where isBody(x, y) {
                g[y][x] = orange
            }
        }

        // Wrap a darker outline around the silhouette.
        for y in 0..<grid {
            for x in 0..<grid where g[y][x] == nil {
                let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                let touchesBody = neighbors.contains { nx, ny in
                    nx >= 0 && nx < grid && ny >= 0 && ny < grid && isBody(nx, ny)
                }
                if touchesBody { g[y][x] = outline }
            }
        }

        // Top highlights for a little shine.
        for (hx, hy) in [(6, 5), (8, 5), (7, 4)] where isBody(hx, hy) {
            g[hy][hx] = highlight
        }

        // Rosy cheeks.
        g[7][4] = blush
        g[7][10] = blush

        return g
    }

    // MARK: - Face

    private static func drawFace(_ gc: inout GraphicsContext, blink: Bool) {
        if blink {
            // Half-closed, sleepy eyes.
            paint(&gc, 5, 7, ink)
            paint(&gc, 9, 7, ink)
        } else {
            // Tall dot eyes.
            paint(&gc, 5, 6, ink); paint(&gc, 5, 7, ink)
            paint(&gc, 9, 6, ink); paint(&gc, 9, 7, ink)
        }

        // Little smile.
        paint(&gc, 6, 9, ink)
        paint(&gc, 7, 9, ink)
        paint(&gc, 8, 9, ink)
    }

    private static func paint(_ gc: inout GraphicsContext, _ x: Int, _ y: Int, _ color: Color) {
        let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
        gc.fill(Path(rect), with: .color(color))
    }
}
