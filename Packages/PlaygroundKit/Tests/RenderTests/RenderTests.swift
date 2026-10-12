import Composition
import CoreGraphics
import Foundation
import Testing
@testable import PlaygroundCore
@testable import Render
import TestSupport
import Timeline

@Suite struct RenderTests {
    static let outDir: URL = {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_OUT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("render-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func snapshot(configure: (inout ProjectDocument) -> Void = { _ in }) -> RenderSnapshot {
        var doc = ProjectDocument()
        doc.scene.slices = Edits.initialSlices(duration: 4)
        configure(&doc)
        var manifest = RecordingManifest()
        manifest.duration = 4
        manifest.captureRect = ScreenRect(x: 0, y: 0, width: 960, height: 540)
        var events = RecordingEvents()
        events.moves = stride(from: 0.0, through: 4, by: 1.0 / 60).map { MouseMove(t: $0, x: 300 + $0 * 120, y: 300, cursor: "a") }
        events.clicks = [MouseClick(t: 2, x: 540, y: 300, phase: .down), MouseClick(t: 2.1, x: 540, y: 300, phase: .up)]
        events.cursors = ["a": CursorImageInfo(id: "a", file: "a.png", hotSpotX: 4, hotSpotY: 3, width: 22, height: 30, systemMatch: "arrow")]
        return RenderSnapshot(document: doc, manifest: manifest, events: events, sourcePixelWidth: 1920, sourcePixelHeight: 1080)
    }

    func render(_ snap: RenderSnapshot, at t: Double, name: String) throws -> CGImage {
        let ctx = try #require(MetalContext.shared)
        let comp = Compositor(context: ctx)
        let size = snap.canvasSize(shortSide: 720)
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(t), width: size.width, height: size.height)
        let screen = FixtureFactory.screenImage(width: 1920, height: 1080, frameIndex: 42).flatMap(ImageIOHelpers.pixelBuffer)
        let img = try #require(comp.renderImage(frame, screen: screen, cursorSet: snap.document.config.cursor.set))
        ImageIOHelpers.writePNG(img, to: Self.outDir.appendingPathComponent("\(name).png"))
        return img
    }

    @Test func defaultLook() throws {
        let img = try render(snapshot(), at: 1, name: "default")
        #expect(img.width == 1280 && img.height == 720)
    }

    @Test func gradientZoomRipple() throws {
        let snap = snapshot {
            $0.config.background.kind = .gradient
            $0.config.cursor.clickEffect = .ripple
            $0.scene.zooms = [ZoomRange(source: SourceRange(1.2, 3.5), level: 2)]
        }
        _ = try render(snap, at: 2.15, name: "zoom-ripple")
        _ = try render(snap, at: 1.35, name: "zoom-motionblur")
    }

    @Test func verticalWithMaskAndLoupe() throws {
        let snap = snapshot {
            $0.config.output.aspect = .vertical
            $0.config.background.kind = .wallpaper
            $0.config.background.wallpaper = "procedural/sunset"
            $0.scene.masks = [MaskRange(source: SourceRange(0, 4), kind: .blur, rect: NormRect(x: 0.7, y: 0.12, width: 0.25, height: 0.32))]
            $0.scene.zooms = [ZoomRange(source: SourceRange(0, 4), level: 2.5, style: .loupe, instant: true)]
        }
        let img = try render(snap, at: 2, name: "vertical-mask-loupe")
        #expect(img.height > img.width)
    }

    @Test func keyboardShortcutKeycaps() throws {
        var snap = snapshot { $0.config.shortcuts.enabled = true }
        snap.shortcuts = [ShortcutEvent(t: 1.8, index: 0, keys: ["⇧", "⌘", "K"])]
        let ctx = try #require(MetalContext.shared)
        let comp = Compositor(context: ctx)
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(2.2), width: 1280, height: 720)
        let caps = try #require(frame.keycaps)
        #expect(caps.keys == ["⇧", "⌘", "K"])
        let screen = FixtureFactory.screenImage(width: 1920, height: 1080, frameIndex: 1).flatMap(ImageIOHelpers.pixelBuffer)
        let img = try #require(comp.renderImage(frame, screen: screen, cursorSet: .system))
        ImageIOHelpers.writePNG(img, to: Self.outDir.appendingPathComponent("keycaps.png"))
        #expect(SceneEvaluator.evaluate(snap, at: OutputTime(3.5), width: 1280, height: 720).keycaps == nil)
    }

    @Test func barcodeRoundTrip() throws {
        let img = try #require(FixtureFactory.screenImage(width: 640, height: 360, frameIndex: 1234))
        let pb = try #require(ImageIOHelpers.pixelBuffer(from: img))
        #expect(FixtureFactory.decodeBarcode(pb) == 1234)
    }
}
