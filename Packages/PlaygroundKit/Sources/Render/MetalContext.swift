@preconcurrency import Metal
@preconcurrency import CoreVideo
import Foundation

public enum RenderError: Error, LocalizedError {
    case noDevice
    case shaderCompile(String)
    case textureCreation

    public var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device available."
        case let .shaderCompile(msg): return "Shader compile failed: \(msg)"
        case .textureCreation: return "Could not create a GPU texture."
        }
    }
}

/// Mirrors `Uniforms` in the shader source (128 bytes, natural alignment).
struct LayerUniforms {
    var rect = SIMD4<Float>.zero
    var uvRect = SIMD4<Float>(0, 0, 1, 1)
    var color = SIMD4<Float>(1, 1, 1, 1)
    var color2 = SIMD4<Float>.zero
    var params = SIMD4<Float>.zero
    var params2 = SIMD4<Float>.zero
    var canvas = SIMD2<Float>.zero
    var pivot = SIMD2<Float>(0.5, 0.5)
    var radius: Float = 0
    var opacity: Float = 1
    var rotation: Float = 0
    var mode: Int32 = 0
}

enum LayerMode: Int32 {
    case solid = 0, texture = 1, shadow = 2, gradient = 3, wallpaper = 4, ring = 5
    case dimOutside = 6, loupe = 7, composite = 8, inset = 9
}

/// Shared GPU objects. Create once and reuse; thread-safe for encoding from one queue at a time.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let overPipeline: MTLRenderPipelineState      // premultiplied "over"
    let addPipeline: MTLRenderPipelineState       // additive (motion-blur accumulation), rgba16f target
    let overPipeline16: MTLRenderPipelineState    // "over" into rgba16f intermediates
    let replacePipeline: MTLRenderPipelineState   // no blending
    public let textureCache: CVMetalTextureCache
    let placeholder: MTLTexture

    public static let shared: MetalContext? = try? MetalContext()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.code, options: nil)
        } catch {
            throw RenderError.shaderCompile("\(error)")
        }
        let vfn = library.makeFunction(name: "layer_vertex")
        let ffn = library.makeFunction(name: "layer_fragment")

        func pipeline(_ format: MTLPixelFormat, blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = ffn
            d.colorAttachments[0].pixelFormat = format
            blend(d.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let over: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = { a in
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        overPipeline = try pipeline(.bgra8Unorm, blend: over)
        overPipeline16 = try pipeline(.rgba16Float, blend: over)
        addPipeline = try pipeline(.rgba16Float) { a in
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.destinationAlphaBlendFactor = .one
        }
        replacePipeline = try pipeline(.bgra8Unorm) { _ in }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RenderError.textureCreation }
        textureCache = cache

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let ph = device.makeTexture(descriptor: td) else { throw RenderError.textureCreation }
        var black: UInt32 = 0xFF00_0000
        ph.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
        placeholder = ph
    }

    /// Wraps a BGRA CVPixelBuffer as a Metal texture without copying.
    public func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        return cvTex.flatMap(CVMetalTextureGetTexture)
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }
}
