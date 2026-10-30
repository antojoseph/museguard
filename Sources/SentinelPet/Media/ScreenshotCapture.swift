import AppKit
import CoreGraphics
import Foundation

struct CapturedScreenshot: Sendable {
    let dataURL: String
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
            return "I could not capture the current window."
        case .encodeFailed:
            return "I captured the current window, but could not prepare the image for local analysis."
        }
    }
}

final class ScreenshotCapture: @unchecked Sendable {
    typealias Operation = @Sendable (CGWindowID, Int, CGFloat) throws -> CapturedScreenshot
    private static let captureQueue = DispatchQueue(label: "MuseGuard.window-capture", qos: .utility)
    private let operation: Operation
    private let onQueued: @Sendable () -> Void

    convenience init() {
        self.init(operation: { window, dimension, compression in
            try Self.capture(windowID: window, maxPixelDimension: dimension, compression: compression)
        })
    }
    init(operation: @escaping Operation, onQueued: @escaping @Sendable () -> Void = {}) {
        self.operation = operation; self.onQueued = onQueued
    }

    func captureAsync(windowID: CGWindowID, maxPixelDimension: Int = 1_400, compression: CGFloat = 0.72) async throws -> CapturedScreenshot {
        try Task.checkCancellation()
        guard windowID != kCGNullWindowID else { throw ScreenshotCaptureError.captureFailed }
        let request = WindowCaptureRequest()
        let screenshot: CapturedScreenshot = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                Self.captureQueue.async { [operation] in
                    guard !request.isCancelled else { return }
                    request.finish(Result { try operation(windowID, maxPixelDimension, compression) })
                }
                onQueued()
            }
        }, onCancel: { request.cancel() })
        try Task.checkCancellation()
        return screenshot
    }

    private static func capture(windowID: CGWindowID, maxPixelDimension: Int, compression: CGFloat) throws -> CapturedScreenshot {
        guard ScreenCapturePermissionController.isTrusted else {
            throw ScreenshotCaptureError.permissionRequired
        }

        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let screenshot = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
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
            dataURL: "data:image/jpeg;base64,\(data.base64EncodedString())"
        )
    }

    private static func downscaled(_ image: CGImage, maxPixelDimension: Int) -> CGImage {
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

private final class WindowCaptureRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CapturedScreenshot, Error>?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ continuation: CheckedContinuation<CapturedScreenshot, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func finish(_ result: Result<CapturedScreenshot, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
