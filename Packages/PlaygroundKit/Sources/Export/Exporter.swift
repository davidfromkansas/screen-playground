@preconcurrency import AVFoundation
import Composition
import CoreVideo
import Foundation
import ImageIO
import Media
@preconcurrency import Metal
import PlaygroundCore
import Render
import UniformTypeIdentifiers

/// Thread-safe cancellation flag shared between the UI and an export.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Renders a project to a video or GIF file using the same evaluator and compositor as the preview.
public final class Exporter: @unchecked Sendable {
    public let project: LoadedProject
    public let document: ProjectDocument
    public let settings: ExportSettings

    public init(project: LoadedProject, document: ProjectDocument? = nil, settings: ExportSettings) {
        self.project = project
        self.document = document ?? project.document
        self.settings = settings
    }

    public func run(to url: URL, cancel: CancelToken = CancelToken(),
                    progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws {
        switch settings.format {
        case .gif: try await exportGIF(to: url, cancel: cancel, progress: progress)
        case .mp4, .prores: try await exportVideo(to: url, cancel: cancel, progress: progress)
        }
    }

    // MARK: - Video

    func exportVideo(to url: URL, cancel: CancelToken, progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let displayURL = project.displayURL else { throw ExportError.noVideo }
        guard let ctx = MetalContext.shared else { throw RenderError.noDevice }
        let snap = project.snapshot(document: document)
        let (w, h) = snap.canvasSize(shortSide: settings.resolution.rawValue)
        let fps = settings.effectiveFPS
        let totalFrames = max(1, Int((snap.duration * Double(fps)).rounded()))

        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = settings.format == .prores ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true // moov atom first: plays while downloading/sharing

        let colorProps: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        var videoSettings: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoColorPropertiesKey: colorProps]
        if settings.format == .prores {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        } else {
            let bitrate = Double(w * h * fps) * settings.quality.bitsPerPixel
            videoSettings[AVVideoCodecKey] = settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
            if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(videoInput)

        // Audio: read the edit's audio composition through an audio-mix output.
        let audio = try await AudioCompositionBuilder.build(document: document, sources: project.audioSources,
                                                            backgroundMusic: LoadedProject.backgroundMusicURL(for: document))
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if audio.hasAudio {
            let tracks = audio.composition.tracks(withMediaType: .audio)
            let reader = try AVAssetReader(asset: audio.composition)
            let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = audio.audioMix
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: snap.duration, preferredTimescale: 48000))
            if reader.canAdd(out) {
                reader.add(out)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioReader = reader
                audioOutput = out
                audioInput = input
            }
        }

        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        audioReader?.startReading()

        let screen = try await VideoFrameSource(url: displayURL)
        let camera: VideoFrameSource? = if let c = project.cameraURL { try await VideoFrameSource(url: c) } else { nil }
        let compositor = Compositor(context: ctx)
        compositor.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        let cursorSet = document.config.cursor.set

        let videoQueue = DispatchQueue(label: "export.video")
        let audioQueue = DispatchQueue(label: "export.audio")
        let state = ExportState()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if cancel.isCancelled || state.failed {
                        videoInput.markAsFinished()
                        if state.markVideoDone() { group.leave() }
                        return
                    }
                    let i = state.nextFrame
                    if i >= totalFrames {
                        videoInput.markAsFinished()
                        if state.markVideoDone() { group.leave() }
                        return
                    }
                    let t = OutputTime(Double(i) / Double(fps))
                    let frame = SceneEvaluator.evaluate(snap, at: t, width: w, height: h, fps: Double(fps))
                    guard let pool = adaptor.pixelBufferPool else { state.fail(); continue }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb, let target = ctx.texture(from: pb), let cb = ctx.queue.makeCommandBuffer() else { state.fail(); continue }
                    let screenTex = screen.frame(at: frame.sourceTime.seconds).flatMap { ctx.texture(from: $0) }
                    let camTex = camera?.frame(at: frame.sourceTime.seconds).flatMap { ctx.texture(from: $0) }
                    compositor.encode(frame, screen: screenTex, camera: camTex, cursorSet: cursorSet, target: target, commandBuffer: cb)
                    cb.commit()
                    cb.waitUntilCompleted()
                    if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                        state.fail()
                        continue
                    }
                    state.nextFrame = i + 1
                    if i % 5 == 0 || i == totalFrames - 1 {
                        progress(ExportProgress(fraction: Double(i + 1) / Double(totalFrames), framesDone: i + 1, framesTotal: totalFrames))
                    }
                }
            }
            if let audioInput, let audioOutput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if cancel.isCancelled || state.failed {
                            audioInput.markAsFinished()
                            if state.markAudioDone() { group.leave() }
                            return
                        }
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            if !audioInput.append(sample) { state.fail() }
                        } else {
                            audioInput.markAsFinished()
                            if state.markAudioDone() { group.leave() }
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { cont.resume() }
        }

        if cancel.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        await writer.finishWriting()
        if writer.status != .completed || state.failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(ExportProgress(fraction: 1, framesDone: totalFrames, framesTotal: totalFrames))
    }

    // MARK: - GIF

    func exportGIF(to url: URL, cancel: CancelToken, progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let displayURL = project.displayURL else { throw ExportError.noVideo }
        guard let ctx = MetalContext.shared else { throw RenderError.noDevice }
        let snap = project.snapshot(document: document)
        var (w, h) = snap.canvasSize(shortSide: min(settings.resolution.rawValue, 1080))
        if w > settings.gifMaxWidth {
            h = Int(Double(h) * Double(settings.gifMaxWidth) / Double(w)) / 2 * 2
            w = settings.gifMaxWidth
        }
        let fps = settings.effectiveFPS
        let total = max(1, Int((snap.duration * Double(fps)).rounded()))
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw ExportError.writerFailed("Could not create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: settings.gifLoopCount]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
                                                           kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)]] as CFDictionary
        let screen = try await VideoFrameSource(url: displayURL)
        let camera: VideoFrameSource? = if let c = project.cameraURL { try await VideoFrameSource(url: c) } else { nil }
        let compositor = Compositor(context: ctx)
        compositor.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        for i in 0..<total {
            if cancel.isCancelled { throw ExportError.cancelled }
            let frame = SceneEvaluator.evaluate(snap, at: OutputTime(Double(i) / Double(fps)), width: w, height: h, fps: Double(fps))
            guard let img = compositor.renderImage(frame, screen: screen.frame(at: frame.sourceTime.seconds),
                                                   camera: camera?.frame(at: frame.sourceTime.seconds),
                                                   cursorSet: document.config.cursor.set) else { continue }
            CGImageDestinationAddImage(dest, img, frameProps)
            if i % 5 == 0 { progress(ExportProgress(fraction: Double(i + 1) / Double(total), framesDone: i + 1, framesTotal: total)) }
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writerFailed("GIF finalize failed") }
        progress(ExportProgress(fraction: 1, framesDone: total, framesTotal: total))
    }
}

/// Shared mutable state of an export, guarded by a lock (accessed from two writer queues).
final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private var _next = 0
    private var _failed = false
    private var videoDone = false
    private var audioDone = false

    var nextFrame: Int {
        get { lock.withLock { _next } }
        set { lock.withLock { _next = newValue } }
    }

    var failed: Bool { lock.withLock { _failed } }
    func fail() { lock.withLock { _failed = true } }

    /// Returns true only the first time (so the dispatch group is left exactly once).
    func markVideoDone() -> Bool { lock.withLock { defer { videoDone = true }; return !videoDone } }
    func markAudioDone() -> Bool { lock.withLock { defer { audioDone = true }; return !audioDone } }
}

/// Puts an exported file on the pasteboard so it pastes as a file into Messages, Slack, Mail, etc.
public enum ClipboardExport {
    public static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Playground/ClipboardExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
