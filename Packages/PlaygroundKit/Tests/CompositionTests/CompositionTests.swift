import Testing
@testable import Composition
@testable import PlaygroundCore
@testable import Timeline

@Suite struct LayoutTests {
    @Test func canvasSizes() {
        #expect(LayoutEngine.canvasSize(aspect: 16.0 / 9, shortSide: 1080) == (1920, 1080))
        #expect(LayoutEngine.canvasSize(aspect: 9.0 / 16, shortSide: 1080) == (1080, 1920))
        let odd = LayoutEngine.canvasSize(aspect: 1512.0 / 828, shortSide: 1080)
        #expect(odd.width % 2 == 0 && odd.height == 1080)
    }

    @Test func paddingShrinksScreen() {
        var cfg = ProjectConfig()
        cfg.frame.padding = 0.1
        let l = LayoutEngine.layout(canvasWidth: 1920, canvasHeight: 1080, contentAspect: 16.0 / 9, config: cfg,
                                    layout: .screenOnly, hasCamera: false)
        #expect(abs(l.screen.height - 1080 * 0.8) < 0.001)
        #expect(abs(l.screen.midX - 960) < 0.001)
    }

    @Test func verticalCanvasFitsWideContent() {
        let l = LayoutEngine.layout(canvasWidth: 1080, canvasHeight: 1920, contentAspect: 16.0 / 9, config: ProjectConfig(),
                                    layout: .screenOnly, hasCamera: false)
        #expect(l.screen.width <= 1080)
        #expect(abs(l.screen.width / l.screen.height - 16.0 / 9) < 0.001)
    }

    @Test func overlayCameraInCorner() {
        let l = LayoutEngine.layout(canvasWidth: 1920, canvasHeight: 1080, contentAspect: 16.0 / 9, config: ProjectConfig(),
                                    layout: .overlay, hasCamera: true)
        let cam = l.camera!
        #expect(cam.maxX > 1800 && cam.maxY > 1000)
    }

    @Test func splitStacksOnPortrait() {
        let l = LayoutEngine.layout(canvasWidth: 1080, canvasHeight: 1920, contentAspect: 16.0 / 9, config: ProjectConfig(),
                                    layout: .split, hasCamera: true)
        #expect(l.camera!.y > l.screen.maxY - 1)
    }
}

@Suite struct EvaluatorTests {
    func snapshot(zoom: ZoomRange? = nil, configure: (inout ProjectDocument) -> Void = { _ in }) -> RenderSnapshot {
        var doc = ProjectDocument()
        doc.scene.slices = Edits.initialSlices(duration: 4)
        if let zoom { doc.scene.zooms = [zoom] }
        configure(&doc)
        var manifest = RecordingManifest()
        manifest.duration = 4
        manifest.captureRect = ScreenRect(x: 0, y: 0, width: 1920, height: 1080)
        var events = RecordingEvents()
        events.moves = stride(from: 0.0, through: 4, by: 0.02).map { MouseMove(t: $0, x: 960, y: 540) }
        return RenderSnapshot(document: doc, manifest: manifest, events: events, sourcePixelWidth: 3840, sourcePixelHeight: 2160)
    }

    @Test func unzoomedScreenMatchesLayout() {
        let f = SceneEvaluator.evaluate(snapshot(), at: OutputTime(1), width: 1920, height: 1080)
        #expect(f.screenQuads.count == 1)
        let q = f.screenQuads[0]
        #expect(abs(q.midX - 960) < 0.5 && abs(q.midY - 540) < 0.5)
        #expect(q.width < 1920)
    }

    @Test func zoomedScreenCoversCanvas() {
        let f = SceneEvaluator.evaluate(snapshot(zoom: ZoomRange(source: SourceRange(0, 4), level: 2, instant: true)),
                                        at: OutputTime(2), width: 1920, height: 1080)
        let q = f.screenQuads.last!
        #expect(q.x <= 0 && q.maxX >= 1920 && q.y <= 0 && q.maxY >= 1080)
    }

    @Test func cursorAtCenter() {
        let f = SceneEvaluator.evaluate(snapshot(), at: OutputTime(2), width: 1920, height: 1080)
        let p = f.cursorPoses.last!
        #expect(abs(p.x - 960) < 1 && abs(p.y - 540) < 1)
    }

    @Test func motionBlurAddsSubsamplesDuringZoom() {
        let snap = snapshot(zoom: ZoomRange(source: SourceRange(1, 3), level: 2.5))
        let f = SceneEvaluator.evaluate(snap, at: OutputTime(1.15), width: 1920, height: 1080)
        #expect(f.screenQuads.count > 1)
        let still = SceneEvaluator.evaluate(snap, at: OutputTime(0.5), width: 1920, height: 1080)
        #expect(still.screenQuads.count == 1)
    }

    @Test func aspectChangeKeepsCanvas() {
        let snap = snapshot { $0.config.output.aspect = .vertical }
        let size = snap.canvasSize(shortSide: 1080)
        #expect(size == (1080, 1920))
    }
}
