import AppKit
@preconcurrency import AVFoundation
import Foundation
import PlaygroundCore
@preconcurrency import ScreenCaptureKit

public struct RecordingOptions: Sendable {
    public var target: RecordingTarget
    public var microphoneID: String?
    public var cameraID: String?
    public var captureSystemAudio = true
    public var fps = 60
    /// Quality of the master recording (bits per pixel per frame, HEVC).
    public var bitsPerPixel = 0.12
    public var hideDesktopIcons = false

    public init(target: RecordingTarget) { self.target = target }
}

public enum RecordingError: Error, LocalizedError {
    case permissionDenied
    case targetNotFound
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required. Enable it in System Settings › Privacy & Security."
        case .targetNotFound: return "The display or window to record could not be found."
        case .noFrames: return "No video was captured."
        }
    }
}

/// One recording from start to finish. Create, `start()`, optionally pause/resume/flag, then `stop()`.
public final class RecordingSession: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    public let bundle: ProjectBundle
    public let options: RecordingOptions
    public let clock = RecordingClock()

    private var stream: SCStream?
    private let screenQueue = DispatchQueue(label: "rec.screen", qos: .userInteractive)
    private let systemAudioQueue = DispatchQueue(label: "rec.sysaudio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "rec.mic", qos: .userInteractive)
    private let cameraQueue = DispatchQueue(label: "rec.camera", qos: .userInteractive)

    private let screenWriter: ChannelWriter
    private let systemAudioWriter: ChannelWriter
    private let micWriter: ChannelWriter
    private let cameraWriter: ChannelWriter
    private var micSession: AVCaptureSession?
    private var cameraSession: AVCaptureSession?
    private var micDelegate: SampleDelegate?
    private var cameraDelegate: SampleDelegate?
    private var input: InputRecorder?
    private var cursor: CursorRecorder?
    private var geometryTimer: DispatchSourceTimer?
    private var geometryWriter: JSONLinesWriter<GeometrySample>?
    private let lock = NSLock()
    private var _micLevel: Float = 0
    private var flags: [Double] = []
    private var manifest = RecordingManifest()
    private var streamError: Error?

    /// Live microphone level 0...1 (for the meter in the recording UI).
    public var micLevel: Float { lock.withLock { _micLevel } }
    public var elapsed: Double { clock.elapsed }
    public var isPaused: Bool { clock.isPaused }
    /// Called if capture stops unexpectedly (display unplugged, window closed).
    public var onUnexpectedStop: (@Sendable (Error?) -> Void)?

    public init(options: RecordingOptions, bundleURL: URL) throws {
        self.options = options
        bundle = try ProjectBundle.create(at: bundleURL)
        let rec = bundle.recordingFolder
        screenWriter = ChannelWriter(url: rec.appendingPathComponent("display.mov"), kind: .video(bitsPerPixel: options.bitsPerPixel, fps: options.fps), clock: clock)
        systemAudioWriter = ChannelWriter(url: rec.appendingPathComponent("system-audio.mov"), kind: .audio, clock: clock)
        micWriter = ChannelWriter(url: rec.appendingPathComponent("microphone.mov"), kind: .audio, clock: clock)
        cameraWriter = ChannelWriter(url: rec.appendingPathComponent("camera.mov"), kind: .video(bitsPerPixel: 0.15, fps: 30), clock: clock)
        super.init()
    }

    // MARK: Start

    public func start() async throws {
        guard PermissionCenter.isGranted(.screenRecording) else { throw RecordingError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let filter: SCContentFilter
        var captureRect: CGRect
        var scale: Double = 2
        var targetName = ""
        var excludedWindows: [SCWindow] = []
        if options.hideDesktopIcons {
            excludedWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer < 0 }
        }

        switch options.target {
        case let .display(id), let .area(id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecordingError.targetNotFound }
            let info = CaptureCatalog.displays().first { $0.id == id }
            scale = info?.pixelScale ?? 2
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: excludedWindows)
            let bounds = CGDisplayBounds(id)
            targetName = info?.name ?? "Display"
            if case let .area(_, rect) = options.target {
                let r = rect.intersection(bounds)
                captureRect = r
                config.sourceRect = CGRect(x: r.minX - bounds.minX, y: r.minY - bounds.minY, width: r.width, height: r.height)
                config.width = Int(r.width * scale) / 2 * 2
                config.height = Int(r.height * scale) / 2 * 2
                targetName = "Area"
            } else {
                captureRect = bounds
                config.width = Int(bounds.width * scale)
                config.height = Int(bounds.height * scale)
            }
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecordingError.targetNotFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureRect = window.frame
            scale = CaptureCatalog.display(containing: window.frame)?.pixelScale ?? 2
            config.width = Int(window.frame.width * scale) / 2 * 2
            config.height = Int(window.frame.height * scale) / 2 * 2
            config.ignoreShadowsSingleWindow = true
            targetName = window.owningApplication?.applicationName ?? (window.title ?? "Window")
        }

        manifest.status = .recording
        manifest.targetName = targetName
        manifest.captureRect = ScreenRect(captureRect)
        manifest.pixelScale = scale
        manifest.refreshRate = Double(options.fps)
        manifest.startUnixTime = Date().timeIntervalSince1970
        switch options.target {
        case .display: manifest.target = .display
        case .window: manifest.target = .window
        case .area: manifest.target = .area
        }
        try bundle.saveManifest(manifest)

        // Inputs
        let input = try InputRecorder(bundle: bundle, clock: clock)
        self.input = input
        try await setUpMicrophone()
        try await setUpCamera()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if options.captureSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue) }
        self.stream = stream
        try await stream.startCapture()

        // Everything shares one origin from here on.
        clock.start()
        input.start()
        micSession?.startRunning()
        cameraSession?.startRunning()
        await MainActor.run {
            let c = CursorRecorder(bundle: bundle, input: input)
            c.start()
            self.cursor = c
        }
        if case let .window(id) = options.target { startGeometryPolling(windowID: id) }
    }

    private func setUpMicrophone() async throws {
        guard let id = options.microphoneID, let device = AVCaptureDevice(uniqueID: id),
              await PermissionCenter.request(.microphone) else { return }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        let delegate = SampleDelegate { [weak self] sample in self?.handleMic(sample) }
        output.setSampleBufferDelegate(delegate, queue: micQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        micSession = session
        micDelegate = delegate
    }

    private func setUpCamera() async throws {
        guard let id = options.cameraID, let device = AVCaptureDevice(uniqueID: id),
              await PermissionCenter.request(.camera) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .hd1920x1080
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        let delegate = SampleDelegate { [weak self] sample in self?.handleCamera(sample) }
        output.setSampleBufferDelegate(delegate, queue: cameraQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        cameraSession = session
        cameraDelegate = delegate
    }

    private func startGeometryPolling(windowID: CGWindowID) {
        geometryWriter = try? JSONLinesWriter(url: bundle.geometryFile)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "rec.geometry"))
        var last: CGRect?
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.clock.sourceTime(host: HostClock.now()),
                  let frame = CaptureCatalog.windowFrame(windowID), frame != last else { return }
            last = frame
            self.geometryWriter?.append(GeometrySample(t: t, rect: ScreenRect(frame)))
        }
        timer.resume()
        geometryTimer = timer
    }

    // MARK: Samples

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Skip idle/blank frames; only complete frames carry an image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            screenWriter.append(sample)
        case .audio:
            systemAudioWriter.append(sample)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
        onUnexpectedStop?(error)
    }

    private func handleMic(_ sample: CMSampleBuffer) {
        guard let session = micSession else { return }
        let converted = Self.convertToHostClock(sample, from: session.synchronizationClock)
        micWriter.append(converted ?? sample)
        // Peak level for the meter.
        if let channel = (micSession?.outputs.first as? AVCaptureAudioDataOutput)?.connections.first?.audioChannels.first {
            let db = channel.averagePowerLevel
            lock.withLock { _micLevel = max(0, min(1, (db + 50) / 50)) }
        }
    }

    private func handleCamera(_ sample: CMSampleBuffer) {
        guard let session = cameraSession else { return }
        cameraWriter.append(Self.convertToHostClock(sample, from: session.synchronizationClock) ?? sample)
    }

    /// AVCapture timestamps are on the session clock; move them onto the host clock.
    static func convertToHostClock(_ sample: CMSampleBuffer, from clock: CMClock?) -> CMSampleBuffer? {
        guard let clock else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        let delta = CMTimeSubtract(host, pts)
        if abs(delta.seconds) < 0.0005 { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, delta)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, delta) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    // MARK: Control

    public func pause() {
        clock.pause()
        lock.withLock { manifest.pauses.append(clock.elapsed) }
    }

    public func resume() { clock.resume() }

    public func addFlag() { lock.withLock { flags.append(clock.elapsed) } }

    /// Stops all capture and finalizes files. Returns the finished bundle.
    public func stop() async throws -> ProjectBundle {
        let duration = clock.elapsed
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        cameraSession?.stopRunning()
        geometryTimer?.cancel()
        geometryWriter?.close()
        input?.stop()
        await MainActor.run { cursor?.stop() }

        // Drain writer queues, then finish files.
        await withCheckedContinuation { c in screenQueue.async { c.resume() } }
        await withCheckedContinuation { c in systemAudioQueue.async { c.resume() } }
        await withCheckedContinuation { c in micQueue.async { c.resume() } }
        await withCheckedContinuation { c in cameraQueue.async { c.resume() } }
        await screenWriter.finish(endTime: duration)
        await systemAudioWriter.finish()
        await micWriter.finish()
        await cameraWriter.finish(endTime: duration)
        guard screenWriter.hasData else { throw streamError ?? RecordingError.noFrames }

        var channels = [ChannelInfo(kind: .display, file: "display.mov", pixelWidth: Int(screenWriter.pixelSize.width),
                                    pixelHeight: Int(screenWriter.pixelSize.height))]
        if systemAudioWriter.hasData { channels.append(ChannelInfo(kind: .systemAudio, file: "system-audio.mov")) }
        if micWriter.hasData { channels.append(ChannelInfo(kind: .microphone, file: "microphone.mov")) }
        if cameraWriter.hasData {
            channels.append(ChannelInfo(kind: .camera, file: "camera.mov", pixelWidth: Int(cameraWriter.pixelSize.width),
                                        pixelHeight: Int(cameraWriter.pixelSize.height)))
        }
        lock.withLock {
            manifest.status = .finished
            manifest.duration = max(duration, 0.1)
            manifest.channels = channels
            manifest.flags = flags
        }
        try bundle.saveManifest(lock.withLock { manifest })
        return bundle
    }

    /// Test hook: stops capture abruptly like a crash, leaving files unfinalized and the manifest
    /// still marked `recording`.
    public func simulateCrash() async {
        try? await stream?.stopCapture()
        geometryTimer?.cancel()
        input?.stop()
        await MainActor.run { cursor?.stop() }
        await withCheckedContinuation { c in screenQueue.async { c.resume() } }
    }

    /// Stops and deletes everything.
    public func cancel() async {
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        cameraSession?.stopRunning()
        geometryTimer?.cancel()
        input?.stop()
        await MainActor.run { cursor?.stop() }
        screenWriter.cancel()
        try? FileManager.default.removeItem(at: bundle.url)
    }
}

/// Bridges AVCapture sample delegates to a closure.
final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let handler: (CMSampleBuffer) -> Void
    init(_ handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
