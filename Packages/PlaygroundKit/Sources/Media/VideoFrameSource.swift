@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import PlaygroundCore

/// Decodes frames of one recorded video channel by source time.
///
/// Sequential requests (playback, export) read forward through a single AVAssetReader; backward
/// or far-forward requests (scrubbing, cuts) restart the reader at the new time. Confine an
/// instance to one thread at a time.
public final class VideoFrameSource: @unchecked Sendable {
    public let url: URL
    public let asset: AVURLAsset
    public private(set) var track: AVAssetTrack?
    public private(set) var naturalSize: CGSize = .zero
    public private(set) var duration: Double = 0
    public private(set) var nominalFrameRate: Double = 60

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, buffer: CVPixelBuffer)?
    private var next: (time: Double, buffer: CVPixelBuffer)?
    private var readerStart: Double = 0
    private var exhausted = false

    /// How far ahead we keep decoding instead of seeking.
    public var maxReadAhead: Double = 1.5

    public init(url: URL) async throws {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        track = tracks.first
        if let track {
            let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            naturalSize = CGSize(width: abs(r.width), height: abs(r.height))
            nominalFrameRate = fps > 0 ? Double(fps) : 60
        }
        duration = try await asset.load(.duration).seconds
    }

    /// The frame visible at source time `t` (the last frame with PTS ≤ t).
    public func frame(at t: Double) -> CVPixelBuffer? {
        let t = max(0, min(t, max(duration - 0.0001, 0)))
        if let c = current, c.time <= t + 0.0005 {
            if let n = next, n.time > t + 0.0005 { return c.buffer }
            if exhausted, next == nil { return c.buffer }
            if t - c.time < maxReadAhead { return readForward(to: t) }
        }
        restart(at: t)
        return readForward(to: t)
    }

    private func readForward(to t: Double) -> CVPixelBuffer? {
        while true {
            if next == nil { next = pull() }
            guard let n = next else {
                exhausted = true
                return current?.buffer
            }
            if n.time <= t + 0.0005 || current == nil {
                current = n
                next = nil
                if n.time > t + 0.0005 { return n.buffer }
            } else {
                return current?.buffer
            }
        }
    }

    private func pull() -> (Double, CVPixelBuffer)? {
        guard let output, let reader, reader.status == .reading else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, pb)
        }
        return nil
    }

    private func restart(at t: Double) {
        reader?.cancelReading()
        reader = nil
        output = nil
        current = nil
        next = nil
        exhausted = false
        guard let track, let r = try? AVAssetReader(asset: asset) else { return }
        // Start slightly early so the frame at `t` (PTS ≤ t) is included.
        let start = max(0, t - 0.1)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        out.alwaysCopiesSampleData = false
        out.supportsRandomAccess = false
        guard r.canAdd(out) else { return }
        r.add(out)
        r.startReading()
        reader = r
        output = out
        readerStart = start
    }

    deinit { reader?.cancelReading() }
}
