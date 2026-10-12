@preconcurrency import AVFoundation
import Capture
import CoreGraphics
import Export
import Foundation
import Media
import PlaygroundCore
@testable import Screen_Playground
import Testing

/// Real ScreenCaptureKit recordings. They run only when this app already has Screen Recording
/// permission (never prompting), never use the microphone or camera, and write to a temp folder.
@MainActor
@Suite(.serialized, .enabled(if: CGPreflightScreenCaptureAccess()))
struct RecorderTests {
    static func url(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-rec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).screenplayground")
    }

    static func record(_ target: RecordingTarget, seconds: Double, pauseAfter: Double? = nil, pauseFor: Double = 0) async throws -> ProjectBundle {
        var options = RecordingOptions(target: target)
        options.captureSystemAudio = false
        let session = try RecordingSession(options: options, bundleURL: url("rec"))
        try await session.start()
        if let pauseAfter {
            try await Task.sleep(nanoseconds: UInt64(pauseAfter * 1e9))
            session.pause()
            try await Task.sleep(nanoseconds: UInt64(pauseFor * 1e9))
            session.resume()
            try await Task.sleep(nanoseconds: UInt64((seconds - pauseAfter) * 1e9))
        } else {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
        return try await session.stop()
    }

    static func videoDuration(_ bundle: ProjectBundle) async throws -> Double {
        let manifest = try bundle.loadManifest()
        let ch = try #require(manifest.channel(.display))
        return try await AVURLAsset(url: bundle.channelURL(ch)).load(.duration).seconds
    }

    @Test func recordDisplay() async throws {
        let display = try #require(CaptureCatalog.displays().first)
        let bundle = try await Self.record(.display(display.id), seconds: 3)
        defer { try? FileManager.default.removeItem(at: bundle.url.deletingLastPathComponent()) }
        let m = try bundle.loadManifest()
        #expect(m.status == .finished)
        #expect(m.target == .display)
        #expect(abs(m.duration - 3) < 0.6)
        #expect((m.channel(.display)?.pixelWidth ?? 0) >= Int(display.frame.width))
        #expect(abs(try await Self.videoDuration(bundle) - 3) < 0.8)
        // Our own windows are excluded and the cursor is not baked in: nothing to assert pixel-wise
        // reliably here, but the cursor index must exist once the mouse has a known image.
        #expect(FileManager.default.fileExists(atPath: bundle.movesFile.path))
    }

    @Test func recordAreaAndEditAndExport() async throws {
        let display = try #require(CaptureCatalog.displays().first)
        let area = CGRect(x: display.frame.minX + 100, y: display.frame.minY + 100, width: 640, height: 400)
        let bundle = try await Self.record(.area(display.id, area), seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: bundle.url.deletingLastPathComponent()) }
        let m = try bundle.loadManifest()
        #expect(m.target == .area)
        #expect(abs(m.captureRect.width - 640) < 1 && abs(m.captureRect.height - 400) < 1)
        let w = m.channel(.display)?.pixelWidth ?? 0, h = m.channel(.display)?.pixelHeight ?? 0
        #expect(abs(Double(w) / Double(max(h, 1)) - 1.6) < 0.02)

        // Same post-processing as the app, then open in the editor model and export.
        try ProjectFactory.finalize(bundle)
        let project = try await LoadedProject.load(bundle)
        var settings = ExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        let out = bundle.url.deletingLastPathComponent().appendingPathComponent("area.mp4")
        try await Exporter(project: project, settings: settings).run(to: out)
        #expect(abs(try await AVURLAsset(url: out).load(.duration).seconds - m.duration) < 0.15)
    }

    @Test func recordWindow() async throws {
        guard let window = CaptureCatalog.windows().first(where: { $0.frame.width > 300 && $0.frame.height > 200 }) else { return }
        let bundle = try await Self.record(.window(window.id), seconds: 2)
        defer { try? FileManager.default.removeItem(at: bundle.url.deletingLastPathComponent()) }
        let m = try bundle.loadManifest()
        #expect(m.target == .window)
        #expect(m.status == .finished)
        #expect(abs(try await Self.videoDuration(bundle) - 2) < 0.8)
    }

    /// Paused time is excluded: 1 s + (1 s paused) + 1 s ≈ 2 s of video.
    @Test func pauseResumeExcludesPausedTime() async throws {
        let display = try #require(CaptureCatalog.displays().first)
        let bundle = try await Self.record(.display(display.id), seconds: 2, pauseAfter: 1, pauseFor: 1.2)
        defer { try? FileManager.default.removeItem(at: bundle.url.deletingLastPathComponent()) }
        let m = try bundle.loadManifest()
        #expect(abs(m.duration - 2) < 0.5)
        #expect(m.pauses.count == 1)
    }

    /// A take that never finishes (crash) is recovered from its 2-second fragments.
    @Test func crashRecovery() async throws {
        let display = try #require(CaptureCatalog.displays().first)
        var options = RecordingOptions(target: .display(display.id))
        options.captureSystemAudio = false
        let bundleURL = Self.url("crash")
        let session = try RecordingSession(options: options, bundleURL: bundleURL)
        try await session.start()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        await session.simulateCrash() // stop capturing without finalizing anything
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let folder = bundleURL.deletingLastPathComponent()
        let pending = RecoveryScanner.unfinishedBundles(in: folder)
        #expect(pending.count == 1)
        #expect(await RecoveryScanner.recover(pending[0]))
        let m = try pending[0].loadManifest()
        #expect(m.status == .recovered)
        #expect(m.duration >= 3.5) // everything up to the last 2-second fragment
        try ProjectFactory.finalize(pending[0])
        let project = try await LoadedProject.load(pending[0])
        #expect(project.document.scene.slices.count == 1)
    }
}
