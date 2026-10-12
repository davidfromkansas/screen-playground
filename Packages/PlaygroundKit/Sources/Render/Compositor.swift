import Composition
import CoreGraphics
import Foundation
@preconcurrency import Metal
@preconcurrency import MetalKit
@preconcurrency import MetalPerformanceShaders
import PlaygroundCore

/// Draws a FrameDescription with Metal. The same instance renders preview and export frames.
/// Confine each instance to one thread/queue at a time.
public final class Compositor: @unchecked Sendable {
    public let context: MetalContext
    private let loader: MTKTextureLoader
    private var cursorsFolder: URL?
    private var cursorInfos: [String: CursorImageInfo] = [:]
    private var cursorTextures: [String: (MTLTexture, CursorArt.Sprite)] = [:]
    private var backgroundCache: (key: String, texture: MTLTexture)?
    private var imageCache: [String: MTLTexture] = [:]
    private var accum: MTLTexture?
    private var scratchA: MTLTexture?
    private var scratchB: MTLTexture?

    public init(context: MetalContext) {
        self.context = context
        loader = MTKTextureLoader(device: context.device)
    }

    /// Sets where recorded cursor images live and their metadata.
    public func setCursorSource(folder: URL?, infos: [String: CursorImageInfo]) {
        if folder != cursorsFolder { cursorTextures.removeAll() }
        cursorsFolder = folder
        cursorInfos = infos
    }

    // MARK: - Frame

    /// Encodes all passes for one frame into `target` (bgra8Unorm, canvas-sized).
    public func encode(_ frame: FrameDescription, screen: MTLTexture?, camera: MTLTexture?, cursorSet: CursorSet,
                       target: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        let canvas = SIMD2<Float>(Float(frame.width), Float(frame.height))
        let screenTex = screen ?? context.placeholder

        // 1. Background
        drawBackground(frame.background, canvas: canvas, target: target, cb: cb)

        // 2–3. Shadow and screen
        if frame.screenOpacity > 0, let main = frame.screenQuads.last {
            let mainQuad = frame.screenQuads[frame.screenQuads.count / 2]
            pass(cb, target: target, load: .load) { enc in
                if frame.shadow.opacity > 0 {
                    let margin = frame.shadow.blur * 2 + abs(frame.shadow.offsetX) + abs(frame.shadow.offsetY)
                    var u = LayerUniforms()
                    u.mode = LayerMode.shadow.rawValue
                    u.canvas = canvas
                    u.rect = SIMD4(Float(mainQuad.x - margin), Float(mainQuad.y - margin),
                                   Float(mainQuad.width + 2 * margin), Float(mainQuad.height + 2 * margin))
                    u.params = SIMD4(Float(mainQuad.x + frame.shadow.offsetX), Float(mainQuad.y + frame.shadow.offsetY),
                                     Float(mainQuad.width), Float(mainQuad.height))
                    u.params2 = SIMD4(Float(frame.shadow.blur), 0, 0, 0)
                    u.radius = Float(frame.cornerRadius)
                    u.color = SIMD4(0, 0, 0, Float(frame.shadow.opacity))
                    u.opacity = Float(frame.screenOpacity)
                    draw(enc, u, pipeline: context.overPipeline)
                }
                if frame.screenQuads.count == 1 {
                    drawScreen(enc, quad: main, frame: frame, texture: screenTex, canvas: canvas, weight: 1, pipeline: context.overPipeline)
                }
            }
            if frame.screenQuads.count > 1, let acc = intermediate(frame) {
                let w = 1 / Float(frame.screenQuads.count)
                pass(cb, target: acc, load: .clear) { enc in
                    for q in frame.screenQuads {
                        drawScreen(enc, quad: q, frame: frame, texture: screenTex, canvas: canvas, weight: w, pipeline: context.addPipeline)
                    }
                }
                composite(acc, onto: target, canvas: canvas, cb: cb)
            }

            // 4. Masks
            if !frame.masks.isEmpty { drawMasks(frame.masks, canvas: canvas, target: target, cb: cb) }

            // 5. Loupe
            if let loupe = frame.loupe {
                pass(cb, target: target, load: .load) { enc in
                    drawLoupe(enc, loupe: loupe, quad: mainQuad, crop: frame.crop, texture: screenTex, canvas: canvas)
                }
            }
        }

        // 6. Camera
        if let cam = frame.camera, let camTex = camera {
            pass(cb, target: target, load: .load) { enc in
                var s = LayerUniforms()
                let margin = min(cam.rect.width, cam.rect.height) * 0.15
                s.mode = LayerMode.shadow.rawValue
                s.canvas = canvas
                s.rect = SIMD4(Float(cam.rect.x - margin), Float(cam.rect.y - margin), Float(cam.rect.width + 2 * margin), Float(cam.rect.height + 2 * margin))
                s.params = SIMD4(Float(cam.rect.x), Float(cam.rect.y + margin * 0.15), Float(cam.rect.width), Float(cam.rect.height))
                s.params2 = SIMD4(Float(margin * 0.6), 0, 0, 0)
                s.radius = Float(cam.cornerRadius)
                s.color = SIMD4(0, 0, 0, 0.35)
                draw(enc, s, pipeline: context.overPipeline)

                var u = LayerUniforms()
                u.mode = LayerMode.texture.rawValue
                u.canvas = canvas
                u.rect = SIMD4(Float(cam.rect.x), Float(cam.rect.y), Float(cam.rect.width), Float(cam.rect.height))
                u.uvRect = SIMD4(Float(cam.crop.x), Float(cam.crop.y), Float(cam.crop.width), Float(cam.crop.height))
                u.radius = Float(cam.cornerRadius)
                u.params = SIMD4(cam.mirror ? 1 : 0, 0, 0, 0)
                u.opacity = Float(cam.opacity)
                draw(enc, u, texture: camTex, pipeline: context.overPipeline)
            }
        }

        // 7. Click effects
        if !frame.clickEffects.isEmpty {
            pass(cb, target: target, load: .load) { enc in
                for e in frame.clickEffects {
                    var u = LayerUniforms()
                    u.mode = LayerMode.ring.rawValue
                    u.canvas = canvas
                    let r = Float(e.radius * 2)
                    u.rect = SIMD4(Float(e.x) - r, Float(e.y) - r, 2 * r, 2 * r)
                    let kind: Float = e.kind == .circle ? 1 : (e.kind == .ripple ? 2 : 3)
                    u.params = SIMD4(Float(e.progress), kind, 0, 0)
                    u.color = e.kind == .circle ? SIMD4(0.25, 0.22, 0.85, 0.9) : SIMD4(0.42, 0.36, 1.0, 0.85)
                    draw(enc, u, pipeline: context.overPipeline)
                }
            }
        }

        // 8. Cursor
        if !frame.cursorPoses.isEmpty, let (tex, sprite) = cursorTexture(id: frame.cursorID, set: cursorSet) {
            if frame.cursorPoses.count == 1 {
                pass(cb, target: target, load: .load) { enc in
                    drawCursor(enc, pose: frame.cursorPoses[0], texture: tex, sprite: sprite, canvas: canvas, weight: 1,
                               pipeline: context.overPipeline)
                }
            } else if let acc = intermediate(frame) {
                let w = 1 / Float(frame.cursorPoses.count)
                pass(cb, target: acc, load: .clear) { enc in
                    for p in frame.cursorPoses {
                        drawCursor(enc, pose: p, texture: tex, sprite: sprite, canvas: canvas, weight: w, pipeline: context.addPipeline)
                    }
                }
                composite(acc, onto: target, canvas: canvas, cb: cb)
            }
        }
    }

    // MARK: - Layers

    private func drawScreen(_ enc: MTLRenderCommandEncoder, quad: PixelRect, frame: FrameDescription, texture: MTLTexture,
                            canvas: SIMD2<Float>, weight: Float, pipeline: MTLRenderPipelineState) {
        var contentRect = quad
        var radius = frame.cornerRadius
        if frame.insetWidth > 0 {
            var bg = LayerUniforms()
            bg.mode = LayerMode.solid.rawValue
            bg.canvas = canvas
            bg.rect = SIMD4(Float(quad.x), Float(quad.y), Float(quad.width), Float(quad.height))
            bg.radius = Float(radius)
            let c = frame.insetColor
            bg.color = SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
            bg.opacity = weight * Float(frame.screenOpacity)
            draw(enc, bg, pipeline: pipeline)
            let inset = frame.insetWidth * quad.width / max(Double(frame.width), 1) * 2
            contentRect = quad.insetBy(inset)
            radius = max(radius - inset, 0)
        }
        var u = LayerUniforms()
        u.mode = LayerMode.texture.rawValue
        u.canvas = canvas
        u.rect = SIMD4(Float(contentRect.x), Float(contentRect.y), Float(contentRect.width), Float(contentRect.height))
        u.uvRect = SIMD4(Float(frame.crop.x), Float(frame.crop.y), Float(frame.crop.width), Float(frame.crop.height))
        u.radius = Float(radius)
        u.opacity = weight * Float(frame.screenOpacity)
        draw(enc, u, texture: texture, pipeline: pipeline)
    }

    private func drawCursor(_ enc: MTLRenderCommandEncoder, pose: CursorPose, texture: MTLTexture, sprite: CursorArt.Sprite,
                            canvas: SIMD2<Float>, weight: Float, pipeline: MTLRenderPipelineState) {
        var u = LayerUniforms()
        u.mode = LayerMode.texture.rawValue
        u.canvas = canvas
        let w = sprite.size.width * pose.scale, h = sprite.size.height * pose.scale
        let hx = sprite.hotSpot.x / max(sprite.size.width, 1), hy = sprite.hotSpot.y / max(sprite.size.height, 1)
        u.rect = SIMD4(Float(pose.x - w * hx), Float(pose.y - h * hy), Float(w), Float(h))
        u.pivot = SIMD2(Float(hx), Float(hy))
        u.rotation = Float(pose.rotation)
        u.params = SIMD4(0, 2, 0, 0) // sprite is premultiplied RGBA
        u.opacity = weight * Float(pose.opacity)
        draw(enc, u, texture: texture, pipeline: pipeline)
    }

    private func drawLoupe(_ enc: MTLRenderCommandEncoder, loupe: LoupeDesc, quad: PixelRect, crop: NormRect,
                           texture: MTLTexture, canvas: SIMD2<Float>) {
        let r = loupe.radius
        // Shadow
        var s = LayerUniforms()
        s.mode = LayerMode.shadow.rawValue
        s.canvas = canvas
        s.rect = SIMD4(Float(loupe.centerX - r * 1.4), Float(loupe.centerY - r * 1.4), Float(r * 2.8), Float(r * 2.8))
        s.params = SIMD4(Float(loupe.centerX - r), Float(loupe.centerY - r + r * 0.06), Float(2 * r), Float(2 * r))
        s.params2 = SIMD4(Float(r * 0.2), 0, 0, 0)
        s.radius = Float(r)
        s.color = SIMD4(0, 0, 0, 0.5 * Float(loupe.opacity))
        draw(enc, s, pipeline: context.overPipeline)

        var u = LayerUniforms()
        u.mode = LayerMode.loupe.rawValue
        u.canvas = canvas
        u.rect = SIMD4(Float(loupe.centerX - r), Float(loupe.centerY - r), Float(2 * r), Float(2 * r))
        let cu = crop.x + (loupe.centerX - quad.x) / quad.width * crop.width
        let cv = crop.y + (loupe.centerY - quad.y) / quad.height * crop.height
        u.params = SIMD4(Float(cu), Float(cv), Float(loupe.magnification), 0)
        u.params2 = SIMD4(Float(2 * r / quad.width * crop.width), Float(2 * r / quad.height * crop.height), 0, 0)
        u.opacity = Float(loupe.opacity)
        draw(enc, u, texture: texture, pipeline: context.overPipeline)
    }

    private func drawMasks(_ masks: [MaskDesc], canvas: SIMD2<Float>, target: MTLTexture, cb: MTLCommandBuffer) {
        let needsBlur = masks.contains { $0.kind == .blur || $0.kind == .blend }
        var blurred: MTLTexture?
        if needsBlur, let a = scratch(&scratchA, like: target), let b = scratch(&scratchB, like: target),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: target, to: a)
            blit.endEncoding()
            let sigma: Float = masks.contains { $0.kind == .blend } ? 60 : 24
            MPSImageGaussianBlur(device: context.device, sigma: sigma).encode(commandBuffer: cb, sourceTexture: a, destinationTexture: b)
            blurred = b
        }
        pass(cb, target: target, load: .load) { enc in
            for m in masks {
                var u = LayerUniforms()
                u.canvas = canvas
                u.rect = SIMD4(Float(m.rect.x), Float(m.rect.y), Float(m.rect.width), Float(m.rect.height))
                u.radius = Float(min(m.rect.width, m.rect.height) * 0.08)
                switch m.kind {
                case .blur, .blend:
                    guard let blurred else { continue }
                    u.mode = LayerMode.texture.rawValue
                    u.uvRect = SIMD4(u.rect.x / canvas.x, u.rect.y / canvas.y, u.rect.z / canvas.x, u.rect.w / canvas.y)
                    draw(enc, u, texture: blurred, pipeline: context.overPipeline)
                case .solid:
                    u.mode = LayerMode.solid.rawValue
                    u.color = SIMD4(0.12, 0.12, 0.14, 1)
                    draw(enc, u, pipeline: context.overPipeline)
                case .highlight:
                    u.mode = LayerMode.dimOutside.rawValue
                    u.params = u.rect
                    u.rect = SIMD4(0, 0, canvas.x, canvas.y)
                    u.opacity = Float(m.opacity)
                    draw(enc, u, pipeline: context.overPipeline)
                }
            }
        }
    }

    // MARK: - Background

    private func drawBackground(_ bg: BackgroundConfig, canvas: SIMD2<Float>, target: MTLTexture, cb: MTLCommandBuffer) {
        let needsCache = bg.blur > 0 || bg.kind == .image || (bg.kind == .wallpaper && bg.wallpaper.hasPrefix("system/"))
        if needsCache, let tex = cachedBackground(bg, target: target, cb: cb) {
            pass(cb, target: target, load: .clear) { enc in
                var u = LayerUniforms()
                u.mode = LayerMode.composite.rawValue
                u.canvas = canvas
                u.rect = SIMD4(0, 0, canvas.x, canvas.y)
                draw(enc, u, texture: tex, pipeline: context.replacePipeline)
            }
            return
        }
        pass(cb, target: target, load: .clear) { enc in
            drawBackgroundDirect(enc, bg, canvas: canvas, pipeline: context.replacePipeline)
        }
    }

    private func drawBackgroundDirect(_ enc: MTLRenderCommandEncoder, _ bg: BackgroundConfig, canvas: SIMD2<Float>,
                                      pipeline: MTLRenderPipelineState) {
        var u = LayerUniforms()
        u.canvas = canvas
        u.rect = SIMD4(0, 0, canvas.x, canvas.y)
        switch bg.kind {
        case .color:
            u.mode = LayerMode.solid.rawValue
            u.color = simd(bg.color)
            draw(enc, u, pipeline: pipeline)
        case .gradient:
            u.mode = LayerMode.gradient.rawValue
            let stops = bg.gradient.stops
            u.color = simd(stops.first?.color ?? .black)
            u.color2 = simd(stops.last?.color ?? .white)
            u.params = SIMD4(Float(bg.gradient.start.x), Float(bg.gradient.start.y), Float(bg.gradient.end.x), Float(bg.gradient.end.y))
            draw(enc, u, pipeline: pipeline)
        case .wallpaper, .image:
            let info = WallpaperCatalog.info(for: bg.wallpaper) ?? WallpaperCatalog.procedural[0]
            u.mode = LayerMode.wallpaper.rawValue
            u.params2 = SIMD4(Float(info.seed), 0, 0, 0)
            var palette = (info.palette.isEmpty ? WallpaperCatalog.procedural[0].palette : info.palette).map(simd)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            enc.setFragmentBytes(&palette, length: MemoryLayout<SIMD4<Float>>.stride * palette.count, index: 1)
            enc.setFragmentTexture(context.placeholder, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func cachedBackground(_ bg: BackgroundConfig, target: MTLTexture, cb: MTLCommandBuffer) -> MTLTexture? {
        let key = "\(bg.kind)|\(bg.wallpaper)|\(bg.imagePath ?? "")|\(bg.blur)|\(bg.gradient)|\(bg.color.hex)|\(target.width)x\(target.height)"
        if let c = backgroundCache, c.key == key { return c.texture }
        guard let base = context.makeTexture(width: target.width, height: target.height, format: .bgra8Unorm,
                                             usage: [.renderTarget, .shaderRead, .shaderWrite]) else { return nil }
        let canvas = SIMD2<Float>(Float(target.width), Float(target.height))
        var imagePath: String?
        if bg.kind == .image { imagePath = bg.imagePath }
        if bg.kind == .wallpaper, bg.wallpaper.hasPrefix("system/") { imagePath = WallpaperCatalog.info(for: bg.wallpaper)?.filePath }

        if let path = imagePath, let img = loadImage(path) {
            // Aspect-fill the image.
            let ia = Double(img.width) / Double(img.height), ca = Double(canvas.x / canvas.y)
            var uv = SIMD4<Float>(0, 0, 1, 1)
            if ia > ca { let w = Float(ca / ia); uv = SIMD4((1 - w) / 2, 0, w, 1) } else { let h = Float(ia / ca); uv = SIMD4(0, (1 - h) / 2, 1, h) }
            pass(cb, target: base, load: .clear) { enc in
                var u = LayerUniforms()
                u.mode = LayerMode.texture.rawValue
                u.canvas = canvas
                u.rect = SIMD4(0, 0, canvas.x, canvas.y)
                u.uvRect = uv
                draw(enc, u, texture: img, pipeline: context.replacePipeline)
            }
        } else {
            var fallback = bg
            if bg.kind == .image || bg.wallpaper.hasPrefix("system/") { fallback.kind = .wallpaper; fallback.wallpaper = "procedural/aurora" }
            pass(cb, target: base, load: .clear) { enc in drawBackgroundDirect(enc, fallback, canvas: canvas, pipeline: context.replacePipeline) }
        }

        var result = base
        if bg.blur > 0, let blurred = context.makeTexture(width: target.width, height: target.height, format: .bgra8Unorm,
                                                          usage: [.renderTarget, .shaderRead, .shaderWrite]) {
            let sigma = Float(bg.blur) * Float(min(target.width, target.height)) / 1080 * 40
            let k = MPSImageGaussianBlur(device: context.device, sigma: max(sigma, 0.5))
            k.edgeMode = .clamp
            k.encode(commandBuffer: cb, sourceTexture: base, destinationTexture: blurred)
            result = blurred
        }
        backgroundCache = (key, result)
        return result
    }

    private func loadImage(_ path: String) -> MTLTexture? {
        if let t = imageCache[path] { return t }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let tex = try? loader.newTexture(cgImage: img, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
        else { return nil }
        imageCache[path] = tex
        return tex
    }

    // MARK: - Cursor textures

    private func cursorTexture(id: String?, set: CursorSet) -> (MTLTexture, CursorArt.Sprite)? {
        let key = "\(set.rawValue)|\(id ?? "arrow")"
        if let t = cursorTextures[key] { return t }
        let info = id.flatMap { cursorInfos[$0] }
        guard let sprite = CursorArt.sprite(for: info, set: set, cursorsFolder: cursorsFolder),
              let tex = try? loader.newTexture(cgImage: sprite.image, options: [.SRGB: false, .generateMipmaps: true,
                                                                               .textureStorageMode: MTLStorageMode.private.rawValue])
        else { return nil }
        cursorTextures[key] = (tex, sprite)
        return (tex, sprite)
    }

    /// Point size and hotspot of the sprite that will be drawn (the art may differ from the recorded cursor).
    public func cursorMetrics(id: String?, set: CursorSet) -> (size: CGSize, hotSpot: CGPoint)? {
        cursorTexture(id: id, set: set).map { ($0.1.size, $0.1.hotSpot) }
    }

    // MARK: - Helpers

    private func intermediate(_ frame: FrameDescription) -> MTLTexture? {
        if let a = accum, a.width == frame.width, a.height == frame.height { return a }
        accum = context.makeTexture(width: frame.width, height: frame.height, format: .rgba16Float)
        return accum
    }

    private func scratch(_ slot: inout MTLTexture?, like target: MTLTexture) -> MTLTexture? {
        if let s = slot, s.width == target.width, s.height == target.height { return s }
        slot = context.makeTexture(width: target.width, height: target.height, format: .bgra8Unorm,
                                   usage: [.renderTarget, .shaderRead, .shaderWrite])
        return slot
    }

    private func composite(_ tex: MTLTexture, onto target: MTLTexture, canvas: SIMD2<Float>, cb: MTLCommandBuffer) {
        pass(cb, target: target, load: .load) { enc in
            var u = LayerUniforms()
            u.mode = LayerMode.composite.rawValue
            u.canvas = canvas
            u.rect = SIMD4(0, 0, canvas.x, canvas.y)
            draw(enc, u, texture: tex, pipeline: context.overPipeline)
        }
    }

    private func pass(_ cb: MTLCommandBuffer, target: MTLTexture, load: MTLLoadAction, _ body: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = load
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        body(enc)
        enc.endEncoding()
    }

    private func draw(_ enc: MTLRenderCommandEncoder, _ u: LayerUniforms, texture: MTLTexture? = nil, pipeline: MTLRenderPipelineState) {
        var u = u
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        var dummy = SIMD4<Float>.zero
        enc.setFragmentBytes(&dummy, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setFragmentTexture(texture ?? context.placeholder, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func simd(_ c: RGBAColor) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
}
