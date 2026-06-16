import AppKit
import CoreGraphics
import Foundation

struct CapturedScreenshot {
    let dataURL: String
    let pixelSize: CGSize
    let byteCount: Int
}

enum ScreenshotCaptureError: LocalizedError {
    case permissionRequired
    case captureFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Screen Recording access is required before I can analyze a screenshot."
        case .captureFailed:
            return "I could not capture the current screen."
        case .encodeFailed:
            return "I captured the screen, but could not prepare the image for Fireworks."
        }
    }
}

final class ScreenshotCapture {
    func capture(maxPixelDimension: Int = 1_400, compression: CGFloat = 0.72) throws -> CapturedScreenshot {
        guard ScreenCapturePermissionController.isTrusted else {
            throw ScreenshotCaptureError.permissionRequired
        }

        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let screenshot = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            imageOptions
        ) else {
            throw ScreenshotCaptureError.captureFailed
        }

        let preparedImage = downscaled(screenshot, maxPixelDimension: maxPixelDimension)
        let bitmap = NSBitmapImageRep(cgImage: preparedImage)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compression]
        ) else {
            throw ScreenshotCaptureError.encodeFailed
        }

        return CapturedScreenshot(
            dataURL: "data:image/jpeg;base64,\(data.base64EncodedString())",
            pixelSize: CGSize(width: preparedImage.width, height: preparedImage.height),
            byteCount: data.count
        )
    }

    private func downscaled(_ image: CGImage, maxPixelDimension: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longestSide = max(width, height)
        guard longestSide > maxPixelDimension else {
            return image
        }

        let scale = CGFloat(maxPixelDimension) / CGFloat(longestSide)
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }
}
