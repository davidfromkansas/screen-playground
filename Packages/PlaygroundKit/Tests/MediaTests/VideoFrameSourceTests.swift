import CoreVideo
import Foundation
import Testing
@testable import Media
import PlaygroundCore
import TestSupport

@Suite(.serialized) struct VideoFrameSourceTests {
    static func fixture(gaps: [ClosedRange<Double>]) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-vfs-\(UUID().uuidString)")
        var opts = FixtureFactory.Options()
        opts.duration = 8
        opts.width = 640
        opts.height = 360
        opts.idleGaps = gaps
        let bundle = try await FixtureFactory.makeProject(at: dir.appendingPathComponent("V.screenplayground"), options: opts)
        return bundle.recordingFolder.appendingPathComponent("display.mp4")
    }

    /// The frame shown at t is always the last frame with timestamp ≤ t, including after a backward seek
    /// into an idle stretch with no frames (real screen recordings are variable frame rate).
    @Test func seeksIntoIdleGapShowLastFrameBefore() async throws {
        let url = try await Self.fixture(gaps: [2.0...5.0])
        let src = try await VideoFrameSource(url: url)
        // Last frame before the gap is index 59 (t = 1.9667 at 30 fps); first after is 151 (t = 5.0333).
        #expect(src.frame(at: 6.0).flatMap { FixtureFactory.decodeBarcode($0) } == 180)
        #expect(src.frame(at: 4.0).flatMap { FixtureFactory.decodeBarcode($0) } == 59)   // backward into the gap
        #expect(src.frame(at: 3.0).flatMap { FixtureFactory.decodeBarcode($0) } == 59)
        #expect(src.frame(at: 5.2).flatMap { FixtureFactory.decodeBarcode($0) } == 156)
        #expect(src.frame(at: 0.5).flatMap { FixtureFactory.decodeBarcode($0) } == 15)   // far backward
        #expect(src.frame(at: 4.9).flatMap { FixtureFactory.decodeBarcode($0) } == 59)   // far forward into the gap
    }

    @Test func randomSeeksMatchConstantRateTruth() async throws {
        let url = try await Self.fixture(gaps: [1.0...1.5, 4.0...6.5])
        let src = try await VideoFrameSource(url: url)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            let t = Double.random(in: 0..<7.9, using: &rng)
            var expected = Int(((t + 0.0005) * 30 + 1e-9).rounded(.down))
            while [1.0...1.5, 4.0...6.5].contains(where: { $0.contains(Double(expected) / 30) }) { expected -= 1 }
            #expect(src.frame(at: t).flatMap { FixtureFactory.decodeBarcode($0) } == expected, "t=\(t)")
        }
    }
}

/// Timing on a real recording (set REAL_VIDEO to a display.mov). Skipped otherwise.
@Suite struct RealRecordingSeekTiming {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REAL_VIDEO"] != nil))
    func seekLatency() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REAL_VIDEO"]!)
        let src = try await VideoFrameSource(url: url)
        var times: [Double] = []
        var nils = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let t = Double.random(in: 0..<src.duration, using: &rng)
            let start = Date()
            if src.frame(at: t) == nil { nils += 1 }
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        times.sort()
        print("REAL seek ms: median \(Int(times[times.count / 2])) p90 \(Int(times[times.count * 9 / 10])) max \(Int(times.last!)) nils \(nils) size \(src.naturalSize)")
        #expect(nils == 0)
    }
}
