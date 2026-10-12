@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import PlaygroundCore

/// Builds synthetic recordings for tests, demos and the CLI — no screen-recording permission needed.
///
/// Every video frame carries a 16-bit barcode of its frame index in the top-left corner so
/// exports can be verified frame-by-frame against the time map.
public enum FixtureFactory {
    public static let barcodeBits = 16
    public static let barcodeCell = 12

    /// Draws a fake app window (sidebar, toolbar, text, buttons) with a frame-index barcode.
    public static func screenImage(width: Int, height: Int, frameIndex: Int, highlight: CGPoint? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        // CG origin is bottom-left; helper to draw in top-left coordinates.
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - y - h, width: w, height: h) }
        func fill(_ r: CGRect, _ g: CGFloat, _ a: CGFloat = 1) {
            ctx.setFillColor(CGColor(gray: g, alpha: a))
            ctx.fill(r)
        }

        fill(rect(0, 0, W, H), 0.98)
        fill(rect(0, 0, W, H * 0.07), 0.92)                       // toolbar
        fill(rect(0, H * 0.07, W * 0.2, H * 0.93), 0.94)          // sidebar
        for i in 0..<10 {                                         // sidebar items
            fill(rect(W * 0.02, H * (0.11 + Double(i) * 0.05), W * 0.14, H * 0.018), 0.75)
        }
        for i in 0..<14 {                                         // body text lines
            let lw = W * (0.55 - CGFloat(i % 3) * 0.08)
            fill(rect(W * 0.25, H * (0.14 + Double(i) * 0.045), lw, H * 0.016), 0.55)
        }
        ctx.setFillColor(CGColor(red: 0.25, green: 0.22, blue: 0.85, alpha: 1))   // primary button
        ctx.fill(rect(W * 0.25, H * 0.82, W * 0.14, H * 0.06))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.45, blue: 0.2, alpha: 1))    // accent card
        ctx.fill(rect(W * 0.72, H * 0.14, W * 0.22, H * 0.3))
        if let p = highlight {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
            ctx.fillEllipse(in: rect(p.x - 20, p.y - 20, 40, 40))
        }
        // Frame-index barcode: white = 1, black = 0, with a red start marker.
        let cell = CGFloat(barcodeCell)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(rect(0, 0, cell, cell))
        for bit in 0..<barcodeBits {
            fill(rect(cell * CGFloat(bit + 1), 0, cell, cell), (frameIndex >> bit) & 1 == 1 ? 1 : 0)
        }
        return ctx.makeImage()
    }

    /// Reads the barcode back from a BGRA pixel buffer of the *source* frame.
    public static func decodeBarcode(_ pb: CVPixelBuffer, cell: Int = barcodeCell) -> Int? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        func luma(_ x: Int, _ y: Int) -> Int {
            let o = y * bpr + x * 4
            return (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
        }
        var value = 0
        for bit in 0..<barcodeBits where luma(cell * (bit + 1) + cell / 2, cell / 2) > 128 { value |= 1 << bit }
        return value
    }

    public struct Options: Sendable {
        public var duration: Double = 6
        public var fps: Int = 30
        public var width: Int = 1920
        public var height: Int = 1080
        public var clickTimes: [Double] = [1.5, 2.2, 4.0]
        /// Time ranges with no video frames, like an idle screen in a real (variable frame rate) recording.
        public var idleGaps: [ClosedRange<Double>] = []
        /// Adds a microphone channel (a 440 Hz tone) and/or a camera channel (640×480, moving dot).
        public var withMicrophone = false
        public var withCamera = false
        public init() {}
    }

    /// Writes a complete `.screenplayground` bundle with video, events, manifest and project.
    @discardableResult
    public static func makeProject(at url: URL, options: Options = Options()) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(at: url)
        let videoURL = bundle.recordingFolder.appendingPathComponent("display.mp4")
        try await writeVideo(to: videoURL, options: options)

        // Points: content is captured at 2x, so the screen is width/2 × height/2 points.
        let ptW = Double(options.width) / 2, ptH = Double(options.height) / 2
        var moves: [MouseMove] = []
        let n = Int(options.duration * 60)
        for i in 0...n {
            let t = Double(i) / 60
            // A Lissajous-ish path across the window.
            let x = ptW * (0.5 + 0.35 * sin(t * 0.9)), y = ptH * (0.5 + 0.3 * sin(t * 1.3 + 0.5))
            moves.append(MouseMove(t: t, x: x, y: y, cursor: "arrow"))
        }
        var clicks: [MouseClick] = []
        for c in options.clickTimes where c < options.duration {
            let m = moves[min(Int(c * 60), moves.count - 1)]
            clicks.append(MouseClick(t: c, x: m.x, y: m.y, phase: .down))
            clicks.append(MouseClick(t: c + 0.09, x: m.x, y: m.y, phase: .up))
        }
        try JSONLines.write(moves, to: bundle.movesFile)
        try JSONLines.write(clicks, to: bundle.clicksFile)
        try JSONLines.write([KeyStroke](), to: bundle.keysFile)
        let arrow = CursorImageInfo(id: "arrow", file: "arrow.png", hotSpotX: 4, hotSpotY: 3, width: 22, height: 30, systemMatch: "arrow")
        try TolerantJSON.encode([arrow]).write(to: bundle.cursorsIndexFile)

        var manifest = RecordingManifest()
        manifest.status = .finished
        manifest.target = .display
        manifest.targetName = "Fixture Display"
        manifest.captureRect = ScreenRect(x: 0, y: 0, width: ptW, height: ptH)
        manifest.pixelScale = 2
        manifest.duration = options.duration
        manifest.channels = [ChannelInfo(kind: .display, file: "display.mp4", pixelWidth: options.width, pixelHeight: options.height)]
        if options.withMicrophone {
            try await writeTone(to: bundle.recordingFolder.appendingPathComponent("microphone.m4a"), seconds: options.duration)
            manifest.channels.append(ChannelInfo(kind: .microphone, file: "microphone.m4a"))
        }
        if options.withCamera {
            try await writeCamera(to: bundle.recordingFolder.appendingPathComponent("camera.mp4"), seconds: options.duration)
            manifest.channels.append(ChannelInfo(kind: .camera, file: "camera.mp4", pixelWidth: 640, pixelHeight: 480))
        }
        try bundle.saveManifest(manifest)

        var doc = ProjectDocument()
        doc.name = url.deletingPathExtension().lastPathComponent
        doc.scene.slices = [Slice(source: SourceRange(0, options.duration))]
        try bundle.saveDocument(doc, keepBackup: false)
        return bundle
    }

    /// 440 Hz tone at -12 dBFS, AAC in an M4A.
    static func writeTone(to url: URL, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        let frames = AVAudioFrameCount(seconds * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.25 * sin(Float(i) * 2 * .pi * 440 / 48000) } }
        try file.write(from: buffer)
    }

    /// A webcam stand-in: soft background with a dot that moves, 30 fps.
    static func writeCamera(to url: URL, seconds: Double) async throws {
        var o = Options()
        o.duration = seconds
        o.fps = 30
        o.width = 640
        o.height = 480
        try await writeVideo(to: url, options: o, frame: { i in
            guard let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 0.85, green: 0.78, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            let x = 320 + 150 * sin(Double(i) / 15)
            ctx.setFillColor(CGColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: x - 60, y: 160, width: 120, height: 160))
            return ctx.makeImage()
        })
    }

    static func writeVideo(to url: URL, options: Options) async throws {
        try await writeVideo(to: url, options: options, frame: { i in screenImage(width: options.width, height: options.height, frameIndex: i) })
    }

    static func writeVideo(to url: URL, options: Options, frame makeFrame: (Int) -> CGImage?) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoMaxKeyFrameIntervalKey: options.fps],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(options.duration * Double(options.fps))
        for i in 0..<frames {
            let t = Double(i) / Double(options.fps)
            if options.idleGaps.contains(where: { $0.contains(t) }) { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb, let img = makeFrame(i) else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: options.width, height: options.height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: options.width, height: options.height))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(options.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
