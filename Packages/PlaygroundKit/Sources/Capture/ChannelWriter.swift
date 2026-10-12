@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import PlaygroundCore

/// Maps host time to source time for every channel. Pausing stops the source clock.
public final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Double?
    private var pausedAt: Double?
    private var pausedTotal: Double = 0

    public init() {}

    public func start(at host: Double = HostClock.now()) { lock.withLock { origin = host } }

    public var isPaused: Bool { lock.withLock { pausedAt != nil } }

    public func pause() {
        lock.withLock { if pausedAt == nil { pausedAt = HostClock.now() } }
    }

    public func resume() {
        lock.withLock {
            if let p = pausedAt {
                pausedTotal += HostClock.now() - p
                pausedAt = nil
            }
        }
    }

    /// Source time for a host timestamp, or nil if before start / while paused.
    public func sourceTime(host: Double) -> Double? {
        lock.withLock {
            guard let origin, pausedAt == nil else { return nil }
            let t = host - origin - pausedTotal
            return t >= 0 ? t : nil
        }
    }

    /// True for timestamps from before the recording started (capture begins a moment before the clock).
    public func isBeforeStart(host: Double) -> Bool {
        lock.withLock { origin.map { host < $0 } ?? true }
    }

    /// Current source time (elapsed recording time excluding pauses).
    public var elapsed: Double {
        lock.withLock {
            guard let origin else { return 0 }
            let now = pausedAt ?? HostClock.now()
            return max(0, now - origin - pausedTotal)
        }
    }
}

/// Writes one channel (screen, camera, mic, system audio) to a fragmented QuickTime movie.
/// Fragments are flushed every 2 seconds, so the file stays readable if the app crashes.
/// Confine to one serial queue.
final class ChannelWriter: @unchecked Sendable {
    enum Kind { case video(bitsPerPixel: Double, fps: Int), audio }

    let url: URL
    let kind: Kind
    let clock: RecordingClock
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var pixelSize: CGSize = .zero
    private(set) var lastTime: Double = 0
    private(set) var failed = false
    /// The newest video frame that arrived before the clock started. Screen frames only come on change,
    /// so on a still screen this may be the only frame: it's written at time zero.
    private var early: CMSampleBuffer?

    init(url: URL, kind: Kind, clock: RecordingClock) {
        self.url = url
        self.kind = kind
        self.clock = clock
    }

    /// Appends a sample whose PTS is on the host clock.
    func append(_ sample: CMSampleBuffer) {
        guard !failed, CMSampleBufferDataIsReady(sample) else { return }
        let hostPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard let t = clock.sourceTime(host: hostPTS) else {
            if case .video = kind, clock.isBeforeStart(host: hostPTS) { early = sample }
            return
        }
        writeEarlyFrame()
        if writer == nil { setUp(for: sample) }
        guard let writer, let input, writer.status == .writing else { return }
        guard input.isReadyForMoreMediaData else { return } // drop rather than block capture
        guard let retimed = retime(sample, offset: hostPTS - t) else { return }
        if input.append(retimed) {
            lastTime = max(lastTime, t)
        } else if writer.status == .failed {
            failed = true
        }
    }

    /// Writes the pre-start frame at source time zero (once).
    private func writeEarlyFrame() {
        guard let sample = early else { return }
        early = nil
        if writer == nil { setUp(for: sample) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let hostPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if let retimed = retime(sample, offset: hostPTS), input.append(retimed) { lastTime = max(lastTime, 0) }
    }

    private func setUp(for sample: CMSampleBuffer) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { failed = true; return }
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let i: AVAssetWriterInput
        switch kind {
        case let .video(bpp, fps):
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { failed = true; return }
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            pixelSize = CGSize(width: width, height: height)
            i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(width * height * fps) * bpp),
                    AVVideoMaxKeyFrameIntervalDurationKey: 1,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        case .audio:
            i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
        }
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { failed = true; return }
        w.add(i)
        guard w.startWriting() else { failed = true; return }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = i
    }

    private func retime(_ sample: CMSampleBuffer, offset: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        let shift = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
        for k in timing.indices {
            if timing[k].presentationTimeStamp.isValid { timing[k].presentationTimeStamp = CMTimeSubtract(timing[k].presentationTimeStamp, shift) }
            if timing[k].decodeTimeStamp.isValid { timing[k].decodeTimeStamp = CMTimeSubtract(timing[k].decodeTimeStamp, shift) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    var hasData: Bool { writer != nil }

    /// Finishes the file. `endTime` (source seconds) extends the last sample to the real end of
    /// the recording, so an idle screen at the end isn't cut off (frames only arrive on change).
    func finish(endTime: Double? = nil) async {
        writeEarlyFrame()
        guard let writer, let input, writer.status == .writing else { return }
        input.markAsFinished()
        if let endTime, endTime > lastTime {
            writer.endSession(atSourceTime: CMTime(seconds: endTime, preferredTimescale: 600))
            lastTime = endTime
        }
        await writer.finishWriting()
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
