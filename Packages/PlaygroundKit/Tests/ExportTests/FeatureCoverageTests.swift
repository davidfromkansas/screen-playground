@preconcurrency import AVFoundation
import Composition
import CoreGraphics
import Foundation
import Media
import Testing
@testable import Export
@testable import PlaygroundCore
@testable import Render
import TestSupport
import Timeline

/// Covers features end to end through the real renderer/exporter: audio, camera, ProRes,
/// backgrounds and cursor styles.
@Suite(.serialized) struct FeatureCoverageTests {
    static func fixture(mic: Bool = false, camera: Bool = false, duration: Double = 4) async throws -> LoadedProject {
        var o = FixtureFactory.Options()
        o.duration = duration
        o.width = 960
        o.height = 540
        o.withMicrophone = mic
        o.withCamera = camera
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-cov-\(UUID().uuidString)")
        let bundle = try await FixtureFactory.makeProject(at: dir.appendingPathComponent("C.screenplayground"), options: o)
        return try await LoadedProject.load(bundle)
    }

    static func out(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pg-cov-\(UUID().uuidString)-\(name)")
    }

    /// RMS (dBFS) of an audio file's samples between two times.
    static func rms(_ url: URL, from a: Double, to b: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return -200 }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        var sum = 0.0, n = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            guard let ptr else { continue }
            let floats = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
            for i in 0..<(length / 4) { sum += Double(floats[i] * floats[i]); n += 1 }
        }
        return n == 0 ? -200 : 10 * log10(sum / Double(n) + 1e-20)
    }

    // MARK: Audio

    @Test func microphoneMuteAndClipVolume() async throws {
        var project = try await Self.fixture(mic: true)
        var s = ExportSettings()
        s.resolution = .p720
        s.fps = 30

        let loud = Self.out("mic.mp4")
        try await Exporter(project: project, settings: s).run(to: loud)
        let level = try await Self.rms(loud, from: 0.5, to: 3.5)
        #expect(level > -25) // the -12 dBFS tone is there

        // A muted second half: split at 2 s and set the right clip's volume to 0.
        var doc = project.document
        doc.scene = try Edits.split(doc.scene, at: OutputTime(2))
        doc.scene.slices[1].volume = 0
        let half = Self.out("half.mp4")
        try await Exporter(project: project, document: doc, settings: s).run(to: half)
        #expect(try await Self.rms(half, from: 0.3, to: 1.7) > -25)
        #expect(try await Self.rms(half, from: 2.4, to: 3.6) < -60)

        // Muting the microphone removes the audio entirely.
        project.document.config.audio.muteMicrophone = true
        let muted = Self.out("muted.mp4")
        try await Exporter(project: project, settings: s).run(to: muted)
        #expect(try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio).isEmpty)
    }

    // MARK: Camera

    @Test func cameraLayouts() async throws {
        let project = try await Self.fixture(camera: true)
        #expect(project.cameraURL != nil)
        let ctx = try #require(MetalContext.shared)
        let comp = Compositor(context: ctx)
        let screen = try await VideoFrameSource(url: project.displayURL!)
        let camera = try await VideoFrameSource(url: project.cameraURL!)

        for layout in [CameraLayoutKind.overlay, .split, .cameraOnly, .screenOnly] {
            var doc = project.document
            doc.config.camera.layout = layout
            let snap = project.snapshot(document: doc)
            let frame = SceneEvaluator.evaluate(snap, at: OutputTime(1), width: 1280, height: 720)
            switch layout {
            case .screenOnly: #expect(frame.camera == nil)
            case .cameraOnly:
                #expect(frame.screenOpacity == 0)
                #expect(frame.camera?.rect.width == 1280)
            default: #expect(frame.camera != nil)
            }
            let img = comp.renderImage(frame, screen: screen.frame(at: 1), camera: camera.frame(at: 1), cursorSet: .system)
            #expect(img != nil, "\(layout) failed to render")
            if let cam = frame.camera, let img {
                // The camera's skin-tone background shows inside the camera rect.
                let p = Self.pixel(img, x: Int(cam.rect.x + cam.rect.width * 0.12), y: Int(cam.rect.y + cam.rect.height * 0.15))
                #expect(p.r > 150 && p.g > 130 && p.b > 110, "\(layout) camera pixel \(p)")
            }
        }

        // Export with the camera overlay.
        var s = ExportSettings()
        s.resolution = .p720
        s.fps = 30
        let out = Self.out("camera.mp4")
        try await Exporter(project: project, settings: s).run(to: out)
        #expect(abs(try await AVURLAsset(url: out).load(.duration).seconds - 4) < 0.1)
    }

    // MARK: ProRes

    @Test func proResExport() async throws {
        let project = try await Self.fixture(duration: 2)
        var s = ExportSettings()
        s.format = .prores
        s.resolution = .p720
        s.fps = 30
        let out = Self.out("prores.mov")
        try await Exporter(project: project, settings: s).run(to: out)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let desc = try await track.load(.formatDescriptions).first!
        #expect(CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_AppleProRes422)
    }

    // MARK: Backgrounds and cursor styles

    @Test func everyBackgroundRenders() async throws {
        let project = try await Self.fixture(duration: 2)
        let ctx = try #require(MetalContext.shared)
        let comp = Compositor(context: ctx)
        let screen = try await VideoFrameSource(url: project.displayURL!)
        let imagePath = FileManager.default.temporaryDirectory.appendingPathComponent("pg-bg-\(UUID().uuidString).png")
        ImageIOHelpers.writePNG(FixtureFactory.screenImage(width: 800, height: 450, frameIndex: 7)!, to: imagePath)

        var configs: [(String, BackgroundConfig)] = []
        var c = BackgroundConfig(); c.kind = .color; c.color = RGBAColor(hex: "#FF0000"); configs.append(("color", c))
        var g = BackgroundConfig(); g.kind = .gradient; configs.append(("gradient", g))
        var w = BackgroundConfig(); w.kind = .wallpaper; w.wallpaper = "procedural/ocean"; configs.append(("wallpaper", w))
        var b = BackgroundConfig(); b.kind = .wallpaper; b.wallpaper = "procedural/sunset"; b.blur = 0.5; configs.append(("blurred", b))
        var i = BackgroundConfig(); i.kind = .image; i.imagePath = imagePath.path; configs.append(("image", i))
        var missing = BackgroundConfig(); missing.kind = .image; missing.imagePath = "/nonexistent.png"; configs.append(("missing image", missing))
        if let sys = WallpaperCatalog.systemWallpapers().first {
            var s = BackgroundConfig(); s.kind = .wallpaper; s.wallpaper = sys.id; configs.append(("system", s))
        }
        for (name, bg) in configs {
            var doc = project.document
            doc.config.background = bg
            doc.config.frame.padding = 0.15
            let snap = project.snapshot(document: doc)
            let frame = SceneEvaluator.evaluate(snap, at: OutputTime(0.5), width: 640, height: 360)
            let img = try #require(comp.renderImage(frame, screen: screen.frame(at: 0.5), cursorSet: .system), "\(name)")
            let corner = Self.pixel(img, x: 4, y: 4)
            if name == "color" { #expect(corner.r > 240 && corner.g < 15 && corner.b < 15, "color bg \(corner)") }
            #expect(corner.a == 255, "\(name) background not opaque")
        }
    }

    @Test func everyCursorStyleHasArt() {
        for set in CursorSet.allCases {
            #expect(CursorArt.sprite(for: nil, set: set, cursorsFolder: nil) != nil, "\(set)")
        }
        for name in ["arrow", "iBeam", "pointingHand", "openHand", "closedHand", "crosshair", "resizeLeftRight"] {
            #expect(CursorArt.systemSprite(named: name) != nil, "\(name)")
        }
    }

    static func pixel(_ img: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: y - img.height + 1, width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }
}
