import Foundation
import Motion
import PlaygroundCore
import Timeline

/// An immutable snapshot of everything needed to render any frame of a project.
/// The editor builds a new one after each edit and hands it to the render thread.
public struct RenderSnapshot: Sendable {
    public var document: ProjectDocument
    public var manifest: RecordingManifest
    public var timeMap: TimeMap
    public var motion: MotionTrack
    public var cursor: CursorTrack
    public var cursorImages: [String: CursorImageInfo]
    public var sourcePixelWidth: Double
    public var sourcePixelHeight: Double
    public var hasCamera: Bool
    public var cameraAspect: Double
    /// Shortcuts to overlay (empty when the overlay is off).
    public var shortcuts: [ShortcutEvent]
    private var keystrokes: [KeyStroke]

    public init(document: ProjectDocument, manifest: RecordingManifest, events: RecordingEvents,
                sourcePixelWidth: Double, sourcePixelHeight: Double, hasCamera: Bool = false, cameraAspect: Double = 16.0 / 9) {
        self.document = document
        self.manifest = manifest
        let cursor = CursorTrack(events: events, captureRect: manifest.captureRect, config: document.config.cursor)
        self.cursor = cursor
        self.cursorImages = events.cursors
        self.timeMap = TimeMap(slices: document.scene.slices)
        self.motion = MotionBuilder.build(MotionInputs(scene: document.scene, config: document.config, cursor: cursor,
                                                       recordingDuration: manifest.duration))
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.hasCamera = hasCamera
        self.cameraAspect = cameraAspect
        self.keystrokes = events.keys
        self.shortcuts = Self.shortcuts(for: document, keys: events.keys)
    }

    static func shortcuts(for doc: ProjectDocument, keys: [KeyStroke]) -> [ShortcutEvent] {
        guard doc.config.shortcuts.enabled else { return [] }
        return ShortcutDetector.detect(keys, includeSingleKeys: doc.config.shortcuts.includeSingleKeys, hidden: doc.scene.hiddenShortcutIndices)
    }

    /// Rebuilds derived data after a document change (reusing the cursor track when cursor settings are unchanged).
    public func updating(document newDoc: ProjectDocument, events: RecordingEvents) -> RenderSnapshot {
        var copy = self
        copy.document = newDoc
        if newDoc.config.cursor != document.config.cursor {
            copy.cursor = CursorTrack(events: events, captureRect: manifest.captureRect, config: newDoc.config.cursor)
        }
        copy.timeMap = TimeMap(slices: newDoc.scene.slices)
        copy.shortcuts = Self.shortcuts(for: newDoc, keys: keystrokes)
        let motionChanged = newDoc.scene != document.scene || newDoc.config.motion != document.config.motion
            || newDoc.config.cursor != document.config.cursor
        if motionChanged {
            copy.motion = MotionBuilder.build(MotionInputs(scene: newDoc.scene, config: newDoc.config, cursor: copy.cursor,
                                                           recordingDuration: manifest.duration))
        }
        return copy
    }

    public var duration: Double { timeMap.duration }

    public var contentAspect: Double {
        LayoutEngine.contentAspect(sourcePixelWidth: sourcePixelWidth, sourcePixelHeight: sourcePixelHeight,
                                   crop: document.config.output.crop)
    }

    /// Canvas size for an export/preview at the given short side.
    public func canvasSize(shortSide: Int) -> (width: Int, height: Int) {
        LayoutEngine.canvasSize(aspect: LayoutEngine.canvasAspect(config: document.config, contentAspect: contentAspect),
                                shortSide: shortSide)
    }
}

/// Turns (snapshot, output time, canvas size) into a FrameDescription.
public enum SceneEvaluator {
    public static func evaluate(_ snap: RenderSnapshot, at t: OutputTime, width: Int, height: Int, fps: Double = 60) -> FrameDescription {
        let doc = snap.document
        let cfg = doc.config
        let w = Double(width), h = Double(height)
        let short = min(w, h)
        let src = snap.timeMap.source(at: t)
        let sourceTime = src?.time ?? .zero

        // Layout for the active camera layout range.
        let layoutRange = doc.scene.layouts.first { $0.source.contains(sourceTime) }
        let layoutKind = layoutRange?.layout ?? cfg.camera.layout
        let layout = LayoutEngine.layout(canvasWidth: w, canvasHeight: h, contentAspect: snap.contentAspect, config: cfg,
                                         layout: layoutKind, hasCamera: snap.hasCamera, cameraSizeOverride: layoutRange?.cameraSize)
        let base = layout.screen
        let pixelsPerPoint = base.width / max(snap.manifest.captureRect.width * cfg.output.crop.width, 1)

        // Motion-blur sub-samples: spread across a 180° shutter, scaled by the blur amount.
        let shutter = 0.5 / fps * cfg.motion.motionBlur
        let center = snap.motion.sample(at: t)
        let probeA = snap.motion.sample(at: t - shutter / 2)
        let probeB = snap.motion.sample(at: t + shutter / 2)

        func quad(for m: MotionSample) -> PixelRect {
            screenQuad(base: base, canvasWidth: w, canvasHeight: h, zoom: m.zoom, focus: cropAdjusted(m.focus, cfg.output.crop))
        }

        let qa = quad(for: probeA), qb = quad(for: probeB)
        let screenTravel = max(abs(qa.x - qb.x), abs(qa.y - qb.y), abs(qa.width - qb.width)) * cfg.motion.motionBlurPan
        let screenK = shutter > 0 ? min(max(Int((screenTravel / 1.5).rounded(.up)), 1), 16) : 1
        let screenQuads = subTimes(t: t, shutter: shutter, count: screenK).map { quad(for: snap.motion.sample(at: $0)) }
        let mainQuad = quad(for: center)

        // Cursor
        let cursorID = cfg.cursor.alwaysUsePointer ? nil : src.flatMap { snap.cursor.cursorID(at: $0.time.seconds) }
        func pose(_ m: MotionSample) -> CursorPose {
            let q = quad(for: m)
            let p = cropAdjusted(m.cursor, cfg.output.crop)
            let ppp = q.width / max(snap.manifest.captureRect.width * cfg.output.crop.width, 1)
            return CursorPose(x: q.x + p.x * q.width, y: q.y + p.y * q.height, scale: cfg.cursor.size * m.clickScale * ppp,
                              rotation: m.cursorRotation, opacity: m.cursorOpacity)
        }
        var cursorPoses: [CursorPose] = []
        if center.cursorOpacity > 0.01 && layout.screenVisible {
            let pa = pose(probeA), pb = pose(probeB)
            let travel = max(abs(pa.x - pb.x), abs(pa.y - pb.y)) * cfg.motion.motionBlurCursor
            let k = shutter > 0 ? min(max(Int((travel / 1.5).rounded(.up)), 1), 24) : 1
            cursorPoses = subTimes(t: t, shutter: shutter, count: k).map { pose(snap.motion.sample(at: $0)) }
        }

        // Click effects
        var effects: [ClickEffectDesc] = []
        if cfg.cursor.clickEffect != .none, let s = src, layout.screenVisible,
           let click = snap.cursor.recentClick(at: s.time.seconds, within: 0.6) {
            let p = cropAdjusted(click.point, cfg.output.crop)
            let pt = mainQuad.point(p)
            effects.append(ClickEffectDesc(kind: cfg.cursor.clickEffect, x: pt.x, y: pt.y, progress: click.age / 0.6,
                                           radius: 28 * pixelsPerPoint * center.zoom * cfg.cursor.size / 1.5))
        }

        // Masks
        let masks = doc.scene.masks.filter { $0.source.contains(sourceTime) }.map { m -> MaskDesc in
            let a = mainQuad.point(cropAdjusted(NormPoint(m.rect.minX, m.rect.minY), cfg.output.crop))
            let b = mainQuad.point(cropAdjusted(NormPoint(m.rect.maxX, m.rect.maxY), cfg.output.crop))
            return MaskDesc(kind: m.kind, rect: PixelRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), opacity: m.opacity)
        }

        // Glass loupe
        var loupe: LoupeDesc?
        if center.loupe > 0.01, layout.screenVisible {
            let zoom = doc.scene.zooms.first { $0.source.contains(sourceTime) && $0.style == .loupe }
            let p = mainQuad.point(cropAdjusted(center.cursor, cfg.output.crop))
            loupe = LoupeDesc(centerX: p.x, centerY: p.y, radius: short * 0.16 * min(center.loupe, 1),
                              magnification: zoom?.level ?? 2, opacity: min(center.loupe, 1))
        }

        // Camera
        var camera: CameraDesc?
        if var rect = layout.camera {
            let isOverlay = layoutKind == .overlay || layoutKind == .cutout
            if isOverlay, center.zoom > 1.01 {
                // Shrink toward its anchor while zoomed so it never hides the action.
                let progress = min((center.zoom - 1) / 0.5, 1)
                let s = 1 + (cfg.camera.scaleDuringZoom - 1) * progress
                let ax = rect.x + rect.width * cfg.camera.position.x, ay = rect.y + rect.height * cfg.camera.position.y
                rect = PixelRect(x: ax - (ax - rect.x) * s, y: ay - (ay - rect.y) * s, width: rect.width * s, height: rect.height * s)
            }
            let targetAspect = rect.width / max(rect.height, 1)
            let radius = isOverlay ? min(rect.width, rect.height) / 2 * cfg.camera.roundness
                : (layoutKind == .cameraOnly ? 0 : cfg.frame.cornerRadius * short / 1080)
            camera = CameraDesc(rect: rect, cornerRadius: radius, mirror: cfg.camera.mirror,
                                crop: aspectCrop(source: snap.cameraAspect, target: targetAspect), opacity: 1)
        }

        // Shadow
        let shadowScale = short / 1080
        let angle = cfg.frame.shadowAngle * .pi / 180
        let dist = cfg.frame.shadowStyle == .directional ? cfg.frame.shadowDistance * shadowScale : cfg.frame.shadowDistance * shadowScale * 0.3
        let shadow = ShadowDesc(opacity: cfg.frame.shadowIntensity * 0.8, blur: cfg.frame.shadowBlur * shadowScale * 2.2,
                                offsetX: cfg.frame.shadowStyle == .directional ? cos(angle) * dist : 0,
                                offsetY: cfg.frame.shadowStyle == .directional ? sin(angle) * dist : dist)

        // Caption (bottom centre), fading over 0.2 s at each end of its range.
        var caption: CaptionDesc?
        if let c = snap.document.scene.captions.first(where: { $0.source.contains(sourceTime) }) {
            let fade = 0.2
            let alpha = min(1, (sourceTime.seconds - c.source.start.seconds) / fade, (c.source.end.seconds - sourceTime.seconds) / fade)
            caption = CaptionDesc(text: c.text, centerX: w / 2, bottomY: h - short * 0.06, fontSize: short * 0.046 * cfg.captions.size,
                                  maxWidth: w * 0.8, opacity: max(0, alpha))
        }

        // Keyboard shortcut overlay (bottom centre, above any caption).
        var keycaps: KeycapDesc?
        if !snap.shortcuts.isEmpty, let (sc, alpha) = ShortcutDetector.active(snap.shortcuts, at: sourceTime.seconds) {
            let height = short * 0.065 * cfg.shortcuts.size
            let lift = caption.map { $0.fontSize * 2.4 + short * 0.02 } ?? 0
            keycaps = KeycapDesc(keys: sc.keys, centerX: w / 2, bottomY: h - short * 0.06 - lift, height: height, opacity: alpha)
        }

        return FrameDescription(
            width: width, height: height, background: cfg.background, sourceTime: sourceTime, crop: cfg.output.crop,
            screenQuads: screenQuads, cornerRadius: cfg.frame.cornerRadius * shortScale(short) * center.zoom,
            shadow: shadow, insetWidth: cfg.frame.insetEnabled ? cfg.frame.inset * shortScale(short) : 0,
            insetColor: RGBAColor(r: cfg.frame.insetColor.r, g: cfg.frame.insetColor.g, b: cfg.frame.insetColor.b,
                                  a: cfg.frame.insetOpacity),
            cursorID: cursorID, cursorPoses: cursorPoses, clickEffects: effects, masks: masks, loupe: loupe,
            camera: camera, keycaps: keycaps, caption: caption, screenOpacity: layout.screenVisible ? 1 : 0)
    }

    static func shortScale(_ short: Double) -> Double { short / 1080 }

    static func subTimes(t: OutputTime, shutter: Double, count: Int) -> [OutputTime] {
        guard count > 1 else { return [t] }
        return (0..<count).map { i in t + (Double(i) / Double(count - 1) - 0.5) * shutter }
    }

    /// Converts a point in full-recording normalized space to cropped space.
    static func cropAdjusted(_ p: NormPoint, _ crop: NormRect) -> NormPoint {
        NormPoint((p.x - crop.x) / max(crop.width, 0.0001), (p.y - crop.y) / max(crop.height, 0.0001))
    }

    /// The screen layer rect for a camera zoom: the focus point stays fixed while the layer scales,
    /// and once the layer is larger than the canvas it is clamped so the background never peeks in.
    static func screenQuad(base: PixelRect, canvasWidth: Double, canvasHeight: Double, zoom: Double, focus: NormPoint) -> PixelRect {
        let z = max(zoom, 1)
        let f = MotionBuilder.clampFocus(focus, zoom: z)
        let w = base.width * z, h = base.height * z
        // Move the focus point toward the canvas center as we zoom in.
        let anchorX = base.x + f.x * base.width, anchorY = base.y + f.y * base.height
        let pull = min((z - 1) / 1.0, 1)
        let cx = anchorX + (canvasWidth / 2 - anchorX) * pull
        let cy = anchorY + (canvasHeight / 2 - anchorY) * pull
        var x = cx - f.x * w, y = cy - f.y * h
        if w >= canvasWidth { x = min(max(x, canvasWidth - w), 0) } else { x = min(max(x, canvasWidth - w - base.x), base.x) }
        if h >= canvasHeight { y = min(max(y, canvasHeight - h), 0) } else { y = min(max(y, canvasHeight - h - base.y), base.y) }
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    /// Crop of a source with `source` aspect that fills a `target` aspect.
    static func aspectCrop(source: Double, target: Double) -> NormRect {
        if source > target {
            let w = target / source
            return NormRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let hgt = source / target
        return NormRect(x: 0, y: (1 - hgt) / 2, width: 1, height: hgt)
    }

}
