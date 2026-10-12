import Composition
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
@preconcurrency import Metal
import PlaygroundCore
import UniformTypeIdentifiers

extension Compositor {
    /// Renders one frame to a CGImage (used for thumbnails, "copy frame", tests and the CLI).
    public func renderImage(_ frame: FrameDescription, screen: CVPixelBuffer?, camera: CVPixelBuffer? = nil,
                            cursorSet: CursorSet) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = context.device.makeTexture(descriptor: d), let cb = context.queue.makeCommandBuffer() else { return nil }
        let screenTex = screen.flatMap { context.texture(from: $0) }
        let camTex = camera.flatMap { context.texture(from: $0) }
        encode(frame, screen: screenTex, camera: camTex, cursorSet: cursorSet, target: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return Self.cgImage(from: target)
    }

    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        texture.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public enum ImageIOHelpers {
    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Creates a BGRA, IOSurface-backed pixel buffer from a CGImage.
    public static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }
}
