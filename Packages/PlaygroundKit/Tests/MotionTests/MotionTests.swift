import Foundation
import Testing
@testable import Motion
@testable import PlaygroundCore
@testable import Timeline

@Suite struct SpringTests {
    /// Semi-implicit Euler at 960 Hz must track the analytic damped oscillator closely.
    @Test func matchesAnalyticSolution() {
        let cfg = SpringConfig.screenDefault
        var s = Spring1D(position: 1, config: cfg)
        let dt = 1 / MotionTrack.stepRate
        let w0 = (cfg.stiffness / cfg.mass).squareRoot()
        let zeta = cfg.damping / (2 * (cfg.stiffness * cfg.mass).squareRoot())
        var maxErr = 0.0
        for i in 1...960 {
            s.step(target: 0, dt: dt)
            let t = Double(i) * dt
            let expected: Double
            if zeta < 1 {
                let wd = w0 * (1 - zeta * zeta).squareRoot()
                expected = exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
            } else {
                let r1 = -w0 * (zeta - (zeta * zeta - 1).squareRoot()), r2 = -w0 * (zeta + (zeta * zeta - 1).squareRoot())
                expected = (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)
            }
            maxErr = max(maxErr, abs(s.position - expected))
        }
        #expect(maxErr < 0.01)
    }

    @Test func allPresetsSettle() {
        let configs = CursorAnimationStyle.allCases.compactMap(\.spring) + ScreenAnimationStyle.allCases.map(\.spring) + [.clickDefault]
        for cfg in configs {
            var s = Spring1D(position: 0, config: cfg)
            for _ in 0..<Int(MotionTrack.stepRate * 3) { s.step(target: 1, dt: 1 / MotionTrack.stepRate) }
            #expect(abs(s.position - 1) < 0.01, "spring \(cfg) did not settle")
        }
    }
}

@Suite struct MotionTrackTests {
    func inputs(zoom: ZoomRange? = nil, configure: (inout ProjectConfig) -> Void = { _ in }) -> MotionInputs {
        var events = RecordingEvents()
        // Cursor sweeps left to right over 4 seconds, clicks at 2s.
        events.moves = stride(from: 0.0, through: 4.0, by: 1.0 / 60).map { MouseMove(t: $0, x: 100 + $0 * 400, y: 500) }
        events.clicks = [MouseClick(t: 2, x: 900, y: 500, phase: .down), MouseClick(t: 2.1, x: 900, y: 500, phase: .up)]
        var scene = Scene()
        scene.slices = Edits.initialSlices(duration: 4)
        if let zoom { scene.zooms = [zoom] }
        var config = ProjectConfig()
        configure(&config)
        let cursor = CursorTrack(events: events, captureRect: ScreenRect(x: 0, y: 0, width: 1920, height: 1080), config: config.cursor)
        return MotionInputs(scene: scene, config: config, cursor: cursor, recordingDuration: 4)
    }

    @Test func deterministic() {
        let a = MotionBuilder.build(inputs(zoom: ZoomRange(source: SourceRange(1, 3))))
        let b = MotionBuilder.build(inputs(zoom: ZoomRange(source: SourceRange(1, 3))))
        #expect(a.samples == b.samples)
    }

    @Test func cursorFollowsWithLag() {
        let track = MotionBuilder.build(inputs())
        let s = track.sample(at: OutputTime(2))
        let raw = (100 + 2 * 400) / 1920.0
        #expect(s.cursor.x < raw) // smoothed cursor trails the raw one
        #expect(abs(s.cursor.x - raw) < 0.05)
    }

    @Test func noneStyleSnaps() {
        let track = MotionBuilder.build(inputs { $0.motion.cursorStyle = .none })
        let s = track.sample(at: OutputTime(2))
        #expect(abs(s.cursor.x - (100 + 2 * 400) / 1920.0) < 0.002)
    }

    @Test func zoomReachesLevelAndReturns() {
        let track = MotionBuilder.build(inputs(zoom: ZoomRange(source: SourceRange(0.5, 2.5), level: 2)))
        #expect(abs(track.sample(at: OutputTime(2.2)).zoom - 2) < 0.05)
        #expect(track.sample(at: OutputTime(3.9)).zoom < 1.1)
        // Viewport stays inside the frame.
        let f = track.sample(at: OutputTime(2.2)).focus
        #expect(f.x >= 0.25 - 1e-6 && f.x <= 0.75 + 1e-6)
    }

    @Test func instantZoomJumps() {
        let track = MotionBuilder.build(inputs(zoom: ZoomRange(source: SourceRange(1, 3), level: 2, instant: true)))
        #expect(abs(track.sample(at: OutputTime(1.01)).zoom - 2) < 0.01)
    }

    @Test func clickScalesCursorDown() {
        let track = MotionBuilder.build(inputs())
        #expect(track.sample(at: OutputTime(2.08)).clickScale < 0.95)
        #expect(abs(track.sample(at: OutputTime(3)).clickScale - 1) < 0.02)
    }

    @Test func idleHideFadesOut() {
        var inp = inputs { $0.cursor.hideWhenIdle = true; $0.cursor.idleHideAfter = 0.5 }
        inp.scene.slices = Edits.initialSlices(duration: 8)
        let track = MotionBuilder.build(inp)
        #expect(track.sample(at: OutputTime(2)).cursorOpacity > 0.95)
        #expect(track.sample(at: OutputTime(7)).cursorOpacity < 0.05)
    }

    @Test func performanceLongRecording() {
        var inp = inputs()
        inp.scene.slices = Edits.initialSlices(duration: 600)
        let start = Date()
        let track = MotionBuilder.build(inp)
        #expect(track.samples.count > 600 * 239)
        // Generous bound for debug builds; release is ~10x faster.
        #expect(Date().timeIntervalSince(start) < 20)
    }
}
