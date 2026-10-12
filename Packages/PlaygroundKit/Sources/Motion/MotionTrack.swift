import Foundation
import PlaygroundCore
import Timeline

/// Animation state at one instant of output time.
public struct MotionSample: Sendable, Equatable {
    public var cursor: NormPoint
    public var cursorVelocity: NormPoint
    public var cursorOpacity: Double
    public var clickScale: Double
    public var cursorRotation: Double
    /// Camera zoom (1 = full frame) and the normalized point at the center of the viewport.
    public var zoom: Double
    public var focus: NormPoint
    /// 0...1 visibility of an active Glass Loupe zoom.
    public var loupe: Double

    public static let identity = MotionSample(cursor: .center, cursorVelocity: NormPoint(0, 0), cursorOpacity: 1,
                                              clickScale: 1, cursorRotation: 0, zoom: 1, focus: .center, loupe: 0)

    static func lerp(_ a: MotionSample, _ b: MotionSample, _ f: Double) -> MotionSample {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        func p(_ x: NormPoint, _ y: NormPoint) -> NormPoint { NormPoint(l(x.x, y.x), l(x.y, y.y)) }
        return MotionSample(cursor: p(a.cursor, b.cursor), cursorVelocity: p(a.cursorVelocity, b.cursorVelocity),
                            cursorOpacity: l(a.cursorOpacity, b.cursorOpacity), clickScale: l(a.clickScale, b.clickScale),
                            cursorRotation: l(a.cursorRotation, b.cursorRotation), zoom: l(a.zoom, b.zoom),
                            focus: p(a.focus, b.focus), loupe: l(a.loupe, b.loupe))
    }
}

/// Spring-simulated cursor and camera motion baked over output time.
///
/// The simulation runs at a fixed 960 Hz step and stores samples at 240 Hz; preview and
/// export both interpolate this same table, so they always agree.
public struct MotionTrack: Sendable {
    public static let stepRate = 960.0
    public static let sampleRate = 240.0

    public let samples: [MotionSample]
    public let duration: Double

    public init(samples: [MotionSample], duration: Double) {
        self.samples = samples
        self.duration = duration
    }

    /// Interpolated sample at output time `t`.
    public func sample(at t: OutputTime) -> MotionSample {
        guard !samples.isEmpty else { return .identity }
        let x = min(max(t.seconds, 0), duration) * Self.sampleRate
        let i = Int(x)
        guard i + 1 < samples.count else { return samples[min(i, samples.count - 1)] }
        return MotionSample.lerp(samples[i], samples[i + 1], x - Double(i))
    }
}

/// Inputs needed to simulate motion for a scene.
public struct MotionInputs: Sendable {
    public var scene: Scene
    public var config: ProjectConfig
    public var cursor: CursorTrack
    public var recordingDuration: Double

    public init(scene: Scene, config: ProjectConfig, cursor: CursorTrack, recordingDuration: Double) {
        self.scene = scene
        self.config = config
        self.cursor = cursor
        self.recordingDuration = recordingDuration
    }
}

public enum MotionBuilder {
    /// Simulates the whole timeline. Cost is linear in output duration (~60 min in well under a second, release build).
    public static func build(_ inputs: MotionInputs) -> MotionTrack {
        let map = TimeMap(slices: inputs.scene.slices)
        let duration = map.duration
        guard duration > 0 else { return MotionTrack(samples: [.identity], duration: 0) }

        let cfg = inputs.config
        let cursor = inputs.cursor
        let dt = 1 / MotionTrack.stepRate
        let stepsPerSample = Int(MotionTrack.stepRate / MotionTrack.sampleRate)
        let totalSteps = Int((duration * MotionTrack.stepRate).rounded(.up))

        let zooms = inputs.scene.zooms.filter { !$0.disabled }
        // Initial focus per zoom: first click inside it, else cursor at its start.
        let zoomFocus: [ItemID: NormPoint] = Dictionary(uniqueKeysWithValues: zooms.map { z in
            let click = cursor.clicks.first { z.source.contains(SourceTime($0.t)) }
            return (z.id, click?.point ?? cursor.position(at: z.source.start.seconds + 0.2))
        })

        func sourceTime(_ t: Double) -> (Slice, Double)? {
            guard let (i, s) = map.source(at: OutputTime(t)) else { return nil }
            return (map.slices[i], s.seconds)
        }

        let firstPos = cursor.position(at: map.slices.first?.source.start.seconds ?? 0)
        let cursorSpring0 = cfg.motion.cursorStyle.spring ?? .mouseDefault
        var cursorSpring = Spring2D(position: firstPos, config: cursorSpring0)
        var clickSpring = Spring1D(position: 1, config: cfg.motion.clickSpring)
        var opacitySpring = Spring1D(position: 1, config: SpringConfig(stiffness: 300, damping: 35, mass: 1))
        var tilt = Spring1D(position: 0, config: SpringConfig(stiffness: 250, damping: 30, mass: 1))
        let screenSpring = cfg.motion.screenStyle.spring
        var logZoom = Spring1D(position: 0, config: screenSpring)
        var focusSpring = Spring2D(position: .center, config: screenSpring)
        var loupeSpring = Spring1D(position: 0, config: screenSpring)

        var activeZoomID: ItemID?
        var focus = NormPoint.center
        var samples: [MotionSample] = []
        samples.reserveCapacity(totalSteps / stepsPerSample + 2)

        let lookAhead = 0.15
        let loopStart = cfg.cursor.loopPosition ? duration - cfg.cursor.loopDuration : .infinity
        let stopAt = cfg.cursor.stopMovementBeforeEnd > 0 ? duration - cfg.cursor.stopMovementBeforeEnd : .infinity

        // Initialize state if the video begins inside a zoom.
        if let (_, s0) = sourceTime(0), let z = zooms.first(where: { $0.source.contains(SourceTime(s0)) }) {
            let f = z.mode == .manual ? z.manualTarget : zoomFocus[z.id] ?? .center
            let clamped = clampFocus(f, zoom: z.level)
            logZoom.snap(to: log(z.style == .loupe ? 1 : z.level))
            focusSpring.snap(to: clamped)
            activeZoomID = z.id
            focus = f
        }

        for step in 0...totalSteps {
            let t = min(Double(step) * dt, duration)
            guard let (slice, src) = sourceTime(t) else { continue }

            // --- Cursor target
            var target = cursor.position(at: src)
            if t >= stopAt, let (_, s2) = sourceTime(stopAt) { target = cursor.position(at: s2) }
            if t >= loopStart { target = firstPos }
            let snapCursor = cfg.motion.cursorStyle == .none || slice.disableSmoothing
            if snapCursor { cursorSpring.snap(to: target) } else { cursorSpring.step(target: target, dt: dt) }

            // --- Visibility: hidden slices, idle fade, outside the captured area.
            var visible = !(cfg.cursor.hidden || slice.hideCursor)
            if cfg.cursor.hideWhenIdle, src - cursor.lastMoveTime(at: src) > cfg.cursor.idleHideAfter { visible = false }
            let p = cursorSpring.position
            if p.x < -0.02 || p.x > 1.02 || p.y < -0.02 || p.y > 1.02 { visible = false }
            if cursor.isEmpty { visible = false }
            opacitySpring.step(target: visible ? 1 : 0, dt: dt)

            clickSpring.step(target: cursor.isPressed(at: src) ? 0.8 : 1, dt: dt)
            let vx = cursorSpring.velocity.x
            tilt.step(target: max(-0.6, min(0.6, vx * cfg.cursor.tiltAmount * 0.9)), dt: dt)

            // --- Camera target
            let zoom = zooms.first { $0.source.contains(SourceTime(src)) }
            var targetZoom = 1.0
            var targetFocus = NormPoint.center
            var targetLoupe = 0.0
            if let z = zoom {
                if activeZoomID != z.id {
                    focus = z.mode == .manual ? z.manualTarget : zoomFocus[z.id] ?? .center
                    activeZoomID = z.id
                    if z.instant {
                        logZoom.snap(to: log(z.style == .loupe ? 1 : z.level))
                        focusSpring.snap(to: clampFocus(focus, zoom: z.level))
                    }
                }
                if z.mode == .auto {
                    // Follow the cursor (with look-ahead) once it leaves the dead zone.
                    let ahead = sourceTime(min(t + lookAhead, duration)).map { cursor.position(at: $0.1) } ?? target
                    let half = 0.5 / z.level * (1 - z.deadZone)
                    if ahead.x < focus.x - half { focus.x = ahead.x + half }
                    if ahead.x > focus.x + half { focus.x = ahead.x - half }
                    if ahead.y < focus.y - half { focus.y = ahead.y + half }
                    if ahead.y > focus.y + half { focus.y = ahead.y - half }
                }
                if z.style == .loupe {
                    targetLoupe = 1
                    targetFocus = clampFocus(focus, zoom: 1)
                } else {
                    targetZoom = z.level
                    targetFocus = clampFocus(focus, zoom: z.level)
                }
            } else {
                activeZoomID = nil
            }
            logZoom.step(target: log(targetZoom), dt: dt)
            focusSpring.step(target: targetFocus, dt: dt)
            loupeSpring.step(target: targetLoupe, dt: dt)

            if step % stepsPerSample == 0 {
                samples.append(MotionSample(
                    cursor: cursorSpring.position,
                    cursorVelocity: cursorSpring.velocity,
                    cursorOpacity: min(max(opacitySpring.position, 0), 1),
                    clickScale: clickSpring.position,
                    cursorRotation: cfg.cursor.rotationMode == .tilt
                        ? tilt.position + cfg.cursor.baseRotation * .pi / 180
                        : followAngle(cursorSpring.velocity) + cfg.cursor.baseRotation * .pi / 180,
                    zoom: max(1, exp(logZoom.position)),
                    focus: focusSpring.position,
                    loupe: min(max(loupeSpring.position, 0), 1.2)))
            }
        }
        return MotionTrack(samples: samples, duration: duration)
    }

    /// Keeps the viewport inside the frame for a given zoom level.
    public static func clampFocus(_ p: NormPoint, zoom: Double) -> NormPoint {
        let half = 0.5 / max(zoom, 1)
        return NormPoint(min(max(p.x, half), 1 - half), min(max(p.y, half), 1 - half))
    }

    static func followAngle(_ v: NormPoint) -> Double {
        let speed = v.length
        guard speed > 0.05 else { return 0 }
        // Pointer art points up-left; rotate so the tip leads the motion, limited to ±35°.
        let angle = atan2(v.y, v.x) + .pi * 0.75
        let wrapped = atan2(sin(angle), cos(angle))
        return max(-0.6, min(0.6, wrapped * min(speed, 1)))
    }
}
