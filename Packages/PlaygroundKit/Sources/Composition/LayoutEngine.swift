import PlaygroundCore

/// Output resolution presets. The value is the length of the canvas's *shorter* side.
public enum ResolutionPreset: Int, Codable, Sendable, CaseIterable {
    case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160

    public var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
}

/// Pure layout math: canvas size, screen rect and camera rect.
public enum LayoutEngine {
    /// Width/height of the recorded content after crop.
    public static func contentAspect(sourcePixelWidth: Double, sourcePixelHeight: Double, crop: NormRect) -> Double {
        (sourcePixelWidth * crop.width) / max(sourcePixelHeight * crop.height, 1)
    }

    /// Canvas size for an aspect ratio, with the shorter side equal to `shortSide`, rounded to even pixels.
    public static func canvasSize(aspect: Double, shortSide: Int) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if aspect >= 1 { return (even(Double(shortSide) * aspect), even(Double(shortSide))) }
        return (even(Double(shortSide)), even(Double(shortSide) / aspect))
    }

    public static func canvasAspect(config: ProjectConfig, contentAspect: Double) -> Double {
        config.output.aspect.value ?? contentAspect
    }

    /// Largest rect of `aspect` that fits inside `bounds`, centered.
    public static func fit(aspect: Double, in bounds: PixelRect) -> PixelRect {
        var w = bounds.width, h = w / aspect
        if h > bounds.height {
            h = bounds.height
            w = h * aspect
        }
        return PixelRect(x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2, width: w, height: h)
    }

    /// Smallest rect of `aspect` that covers `bounds`, centered.
    public static func cover(aspect: Double, bounds: PixelRect) -> PixelRect {
        var w = bounds.width, h = w / aspect
        if h < bounds.height {
            h = bounds.height
            w = h * aspect
        }
        return PixelRect(x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2, width: w, height: h)
    }

    public struct Layout: Sendable {
        public var screen: PixelRect
        public var camera: PixelRect?
        public var screenVisible: Bool
    }

    /// Positions the screen and camera for a layout.
    public static func layout(canvasWidth: Double, canvasHeight: Double, contentAspect: Double,
                              config: ProjectConfig, layout kind: CameraLayoutKind, hasCamera: Bool,
                              cameraSizeOverride: Double? = nil) -> Layout {
        let canvas = PixelRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let short = min(canvasWidth, canvasHeight)
        let pad = config.frame.padding * short
        let available = canvas.insetBy(pad)
        let cam = config.camera
        let showCamera = hasCamera && !cam.hidden && kind != .screenOnly

        switch (showCamera ? kind : .screenOnly) {
        case .split:
            // Side by side on landscape canvases, stacked on portrait ones.
            let gap = pad > 0 ? pad / 2 : 0
            if canvasWidth >= canvasHeight {
                let camW = available.width * 0.32
                let screenBounds = PixelRect(x: available.x, y: available.y, width: available.width - camW - gap, height: available.height)
                let camBounds = PixelRect(x: screenBounds.maxX + gap, y: available.y, width: camW, height: available.height)
                return Layout(screen: fit(aspect: contentAspect, in: screenBounds), camera: camBounds, screenVisible: true)
            } else {
                let camH = available.height * 0.38
                let screenBounds = PixelRect(x: available.x, y: available.y, width: available.width, height: available.height - camH - gap)
                let camBounds = PixelRect(x: available.x, y: screenBounds.maxY + gap, width: available.width, height: camH)
                return Layout(screen: fit(aspect: contentAspect, in: screenBounds), camera: camBounds, screenVisible: true)
            }
        case .cameraOnly:
            return Layout(screen: fit(aspect: contentAspect, in: available), camera: canvas, screenVisible: false)
        case .overlay, .cutout:
            let screen = fit(aspect: contentAspect, in: available)
            let size = (cameraSizeOverride ?? cam.size) * short
            let w = cam.aspect.value >= 1 ? size * cam.aspect.value : size
            let h = cam.aspect.value >= 1 ? size : size / cam.aspect.value
            let margin = max(short * 0.03, pad * 0.5)
            let x = margin + (canvasWidth - w - 2 * margin) * min(max(cam.position.x, 0), 1)
            let y = margin + (canvasHeight - h - 2 * margin) * min(max(cam.position.y, 0), 1)
            return Layout(screen: screen, camera: PixelRect(x: x, y: y, width: w, height: h), screenVisible: true)
        case .screenOnly:
            return Layout(screen: fit(aspect: contentAspect, in: available), camera: nil, screenVisible: true)
        }
    }
}
