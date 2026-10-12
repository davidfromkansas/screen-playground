// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaygroundKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlaygroundCore", targets: ["PlaygroundCore"]),
        .library(name: "Timeline", targets: ["Timeline"]),
        .library(name: "Motion", targets: ["Motion"]),
        .library(name: "Composition", targets: ["Composition"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Media", targets: ["Media"]),
        .library(name: "Export", targets: ["Export"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        // Pure Swift: domain model, project format, time.
        .target(name: "PlaygroundCore"),
        // Pure Swift: time mapping, edits, auto-zoom, detectors.
        .target(name: "Timeline", dependencies: ["PlaygroundCore"]),
        // Pure Swift: springs, cursor and camera paths.
        .target(name: "Motion", dependencies: ["PlaygroundCore", "Timeline"]),
        // Pure Swift: scene evaluation into a FrameDescription.
        .target(name: "Composition", dependencies: ["PlaygroundCore", "Timeline", "Motion"]),
        // Metal compositor (shaders compiled at runtime from source).
        .target(name: "Render", dependencies: ["Composition"]),
        // Decoding, audio composition, playback.
        .target(name: "Media", dependencies: ["Render", "Timeline"]),
        // MP4 / GIF / clipboard export.
        .target(name: "Export", dependencies: ["Media", "Render"]),
        // ScreenCaptureKit recorder, input events, segmented writer.
        .target(name: "Capture", dependencies: ["PlaygroundCore"]),
        // Synthetic fixtures for tests and pgctl.
        .target(name: "TestSupport", dependencies: ["PlaygroundCore", "Capture"]),

        .testTarget(name: "PlaygroundCoreTests", dependencies: ["PlaygroundCore"]),
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"]),
        .testTarget(name: "MotionTests", dependencies: ["Motion"]),
        .testTarget(name: "CompositionTests", dependencies: ["Composition"]),
        .testTarget(name: "RenderTests", dependencies: ["Render", "TestSupport"]),
        .testTarget(name: "ExportTests", dependencies: ["Export", "TestSupport"]),
    ]
)
