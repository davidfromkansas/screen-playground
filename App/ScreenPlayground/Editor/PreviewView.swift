import AppKit
import Composition
import Media
@preconcurrency import Metal
@preconcurrency import QuartzCore
import PlaygroundCore
import Render
import SwiftUI

/// Renders the edited video live. Shares the evaluator + compositor with export, so what you
/// see is exactly what you get.
struct PreviewView: NSViewRepresentable {
    var model: EditorModel

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        if let p = model.project { v.renderer.configure(project: p) }
        return v
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        _ = model.renderGeneration // observe
        if let p = model.project, !view.renderer.isConfigured { view.renderer.configure(project: p) }
        guard let snap = model.snapshot else { return }
        view.request(snapshot: snap, time: model.time, playing: model.isPlaying)
    }
}

final class PreviewNSView: NSView {
    let renderer = PreviewRenderer()
    private let metalLayer = CAMetalLayer()
    private var lastSnapshot: RenderSnapshot?
    private var lastTime: Double = 0
    private var lastPlaying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        metalLayer.device = MetalContext.shared?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.cornerRadius = 6
        metalLayer.masksToBounds = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let s = lastSnapshot { request(snapshot: s, time: lastTime, playing: lastPlaying) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let s = lastSnapshot { request(snapshot: s, time: lastTime, playing: lastPlaying) }
    }

    func request(snapshot: RenderSnapshot, time: Double, playing: Bool) {
        lastSnapshot = snapshot
        lastTime = time
        lastPlaying = playing
        let scale = window?.backingScaleFactor ?? 2
        let bounds = self.bounds
        guard bounds.width > 10, bounds.height > 10 else { return }
        // Fit the canvas aspect into the view.
        let full = snapshot.canvasSize(shortSide: 1080)
        let aspect = Double(full.width) / Double(full.height)
        var w = bounds.width, h = w / aspect
        if h > bounds.height { h = bounds.height; w = h * aspect }
        let frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = frame
        CATransaction.commit()
        // Cap preview resolution to keep playback smooth.
        let shortSide = min(Int(min(w, h) * scale), 1440)
        let size = snapshot.canvasSize(shortSide: max(shortSide, 2))
        renderer.render(snapshot: snapshot, time: time, size: size, layer: metalLayer)
    }
}

/// Owns decoders and the compositor; renders on its own queue, always drawing the latest request.
final class PreviewRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "preview.render", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (RenderSnapshot, Double, (Int, Int), CAMetalLayer)?
    private var lastJob: (RenderSnapshot, Double, (Int, Int), CAMetalLayer)?
    private var busy = false
    private var compositor: Compositor?
    private var screen: VideoFrameSource?
    private var camera: VideoFrameSource?
    private(set) var isConfigured = false

    func configure(project: LoadedProject) {
        isConfigured = true
        guard let ctx = MetalContext.shared else { return }
        let comp = Compositor(context: ctx)
        comp.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        compositor = comp
        let displayURL = project.displayURL, cameraURL = project.cameraURL
        Task {
            let s = try? await displayURL.asyncMap { try await VideoFrameSource(url: $0) }
            let c = try? await cameraURL.asyncMap { try await VideoFrameSource(url: $0) }
            self.queue.async {
                self.screen = s ?? nil
                self.camera = c ?? nil
                // Redraw the last frame now that video is available.
                self.lock.withLock { if self.pending == nil { self.pending = self.lastJob } }
                self.drain()
            }
        }
    }

    func render(snapshot: RenderSnapshot, time: Double, size: (Int, Int), layer: CAMetalLayer) {
        lock.withLock {
            pending = (snapshot, time, size, layer)
            lastJob = pending
        }
        queue.async { self.drain() }
    }

    private func drain() {
        let job: (RenderSnapshot, Double, (Int, Int), CAMetalLayer)? = lock.withLock {
            guard !busy, let p = pending else { return nil }
            busy = true
            pending = nil
            return p
        }
        guard let (snap, time, size, layer) = job else { return }
        defer {
            lock.withLock { busy = false }
            if lock.withLock({ pending != nil }) { queue.async { self.drain() } }
        }
        guard let ctx = MetalContext.shared, let compositor else { return }
        if layer.drawableSize != CGSize(width: size.0, height: size.1) {
            layer.drawableSize = CGSize(width: size.0, height: size.1)
        }
        guard let drawable = layer.nextDrawable(), let cb = ctx.queue.makeCommandBuffer() else { return }
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(time), width: size.0, height: size.1)
        let screenTex = screen?.frame(at: frame.sourceTime.seconds).flatMap { ctx.texture(from: $0) }
        let camTex = camera?.frame(at: frame.sourceTime.seconds).flatMap { ctx.texture(from: $0) }
        compositor.encode(frame, screen: screenTex, camera: camTex, cursorSet: snap.document.config.cursor.set,
                          target: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
        cb.waitUntilScheduled()
    }

    /// Renders a still at full quality (for "Copy frame").
    func stillImage(snapshot: RenderSnapshot, time: Double) -> CGImage? {
        queue.sync {
            guard let compositor else { return nil }
            let size = snapshot.canvasSize(shortSide: 1080)
            let frame = SceneEvaluator.evaluate(snapshot, at: OutputTime(time), width: size.width, height: size.height)
            return compositor.renderImage(frame, screen: screen?.frame(at: frame.sourceTime.seconds),
                                          camera: camera?.frame(at: frame.sourceTime.seconds), cursorSet: snapshot.document.config.cursor.set)
        }
    }
}

extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        switch self {
        case let .some(v): return try await transform(v)
        case .none: return nil
        }
    }
}
