import Composition
import Export
import Foundation
import Media
import PlaygroundCore
import Render
import TestSupport
import Timeline

/// Command-line control of Screen Playground, for people, scripts and AI agents.
/// Every command accepts `--json` for one machine-readable JSON object on stdout.
@main
struct PGCtl {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--json") { Output.json = true; args.remove(at: i) }
        guard let command = args.first else { usage() }
        args.removeFirst()
        do {
            switch command {
            case "status": try LiveCommands.status()
            case "targets": try LiveCommands.targets()
            case "record": try LiveCommands.record(args)
            case "mark": try LiveCommands.mark(args)
            case "run": try LiveCommands.run(args)
            case "install": try Installer.run(args)
            case "mcp": MCPServer.serve()
            case "edit": try await EditCommands.edit(args)
            case "frames": try await EditCommands.frames(args)
            case "make-fixture": try await makeFixture(args)
            case "export": try await export(args)
            case "render-frame": try await renderFrame(args)
            case "info": try await info(args)
            case "help", "--help", "-h":
                if args.first == "script" { print(ScriptHelp.text); exit(0) }
                usage(exitCode: 0)
            default: usage()
            }
        } catch {
            Output.fail(error)
        }
    }

    static func usage(exitCode: Int32 = 2) -> Never {
        print("""
        pgctl — control Screen Playground from the terminal (add --json to any command for agent-friendly output)

        Demo scripts (the app clicks and types for you while recording; press Esc to stop):
          pgctl run demo.json [--check] [--output out.mp4] [--folder DIR] [--open-editor]
          pgctl help script                              the script format, with an example

        Recording (drives the Screen Playground app; it launches in the background if needed):
          pgctl status                                   app version and permissions
          pgctl targets                                  displays and windows you can record
          pgctl record start [--app Safari [--title T] | --window ID | --display N | --area x,y,w,h]
                             [--mic [name]] [--system-audio] [--countdown 0] [--max-duration S] [--name N] [--folder DIR] [--cut-idle 1.5] [--open-editor]
          pgctl record stop [--open-editor]              finish, auto-zoom, save; prints the project path
          pgctl record cancel | status
          pgctl mark caption "text" [--for S]            annotate the recording at this moment
          pgctl mark zoom [level] | cut-start | cut-end | speed-start [x] | speed-end | hold [S] | note "text"

        Setup:
          pgctl install [--force] [--for claude-code|claude-desktop|codex]
                                                         link pgctl into ~/.local/bin and connect an agent app
          pgctl mcp                                      run as an MCP server (stdio) for agent apps

        Projects (no app needed):
          pgctl info <project>
          pgctl export <project> <out.mp4|.gif|.mov> [--res 720|1080|1440|2160] [--fps 60] [--quality studio|social|web|webLow]
                       [--aspect auto|16:9|9:16|1:1|4:3|3:4|4:5] [--cut from:to] [--speed from:to:x] [--auto-zoom] [--preset file]
          pgctl edit <project> [--caption from:to:"text"] [--zoom from:to[:level[:x,y]]] [--cut from:to] [--speed from:to:x]
                     [--cut-idle 1.5] [--apply-marks] [--auto-zoom] [--preset file] [--aspect 9:16]
                     [--clear-captions] [--clear-zooms] [--output-time]   saves the project (times are source seconds
                     unless --output-time)
          pgctl frames <project> [--every 2] [--res 540] [--out DIR]   PNGs + a contact sheet to review the result
          pgctl render-frame <project> <seconds> <out.png> [--res 1080]
          pgctl make-fixture <out.screenplayground> [--duration 6] [--clicks 1.5,2.2,4]
        """)
        exit(exitCode)
    }

    static func option(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func options(_ args: [String], _ name: String) -> [String] {
        args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    static func makeFixture(_ args: [String]) async throws {
        guard let path = args.first else { usage() }
        var opts = FixtureFactory.Options()
        if let d = option(args, "--duration").flatMap(Double.init) { opts.duration = d }
        if let c = option(args, "--clicks") { opts.clickTimes = c.split(separator: ",").compactMap { Double($0) } }
        let bundle = try await FixtureFactory.makeProject(at: URL(fileURLWithPath: path), options: opts)
        Output.emit(["project": .string(bundle.url.path)]) { bundle.url.path }
    }

    /// Applies command-line edits (aspect, cuts, speed, preset) to a document.
    static func edited(_ project: LoadedProject, _ args: [String]) throws -> ProjectDocument {
        var doc = project.document
        if let presetPath = option(args, "--preset") {
            let data = try Data(contentsOf: URL(fileURLWithPath: presetPath))
            struct PresetFile: Codable { var config: ProjectConfig }
            doc.config = try TolerantJSON.decode(PresetFile.self, from: data, defaults: PresetFile(config: doc.config)).config
        }
        if let a = option(args, "--aspect"), let aspect = AspectRatio(rawValue: a) { doc.config.output.aspect = aspect }
        // Cuts and speed changes are expressed in source seconds.
        var scene = doc.scene
        for spec in options(args, "--cut") {
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2 else { continue }
            scene = try Edits.removeSource(scene, range: SourceRange(p[0], p[1]))
        }
        for spec in options(args, "--speed") {
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard p.count == 3 else { continue }
            scene = Edits.setSpeed(scene, source: SourceRange(p[0], p[1]), speed: p[2])
        }
        if args.contains("--auto-zoom") {
            let clicks = project.events.downClicks.map { AutoZoom.Click(t: $0.t, point: project.manifest.captureRect.normalize(x: $0.x, y: $0.y)) }
            scene = AutoZoom.regenerate(scene, clicks: clicks, duration: project.manifest.duration, config: doc.config.autoZoom)
        }
        doc.scene = scene
        return doc
    }

    static func export(_ args: [String]) async throws {
        guard args.count >= 2 else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: args[0])))
        let out = URL(fileURLWithPath: args[1])
        var settings = ExportSettings()
        switch out.pathExtension.lowercased() {
        case "gif": settings = .gifDefault
        case "mov": settings.format = .prores
        default: settings.format = .mp4
        }
        if let r = option(args, "--res").flatMap(Int.init), let preset = ResolutionPreset(rawValue: r) { settings.resolution = preset }
        if let f = option(args, "--fps").flatMap(Int.init) { settings.fps = f }
        if let q = option(args, "--quality").flatMap(ExportQuality.init) { settings.quality = q }
        if option(args, "--codec") == "hevc" { settings.codec = .hevc }
        let doc = try edited(project, args)
        let start = Date()
        try await Exporter(project: project, document: doc, settings: settings).run(to: out) { p in
            if p.framesDone % 60 == 0 || p.fraction >= 1 {
                FileHandle.standardError.write(Data("\r\(Int(p.fraction * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        let seconds = Date().timeIntervalSince(start)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        let duration = TimeMap(slices: doc.scene.slices).duration
        Output.emit(["output": .string(out.path), "bytes": .number(Double(bytes)), "duration": .number((duration * 100).rounded() / 100),
                     "renderSeconds": .number((seconds * 100).rounded() / 100)]) {
            "exported \(out.path) in \(String(format: "%.2f", seconds))s"
        }
    }

    static func renderFrame(_ args: [String]) async throws {
        guard args.count >= 3, let t = Double(args[1]) else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: args[0])))
        let doc = try edited(project, args)
        let snap = project.snapshot(document: doc)
        let res = option(args, "--res").flatMap(Int.init) ?? 1080
        let size = snap.canvasSize(shortSide: res)
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(t), width: size.width, height: size.height)
        guard let ctx = MetalContext.shared else { throw RenderError.noDevice }
        let comp = Compositor(context: ctx)
        comp.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        let screen = try await project.displayURL.map { try await VideoFrameSource(url: $0) }
        let camera = try await project.cameraURL.map { try await VideoFrameSource(url: $0) }
        guard let img = comp.renderImage(frame, screen: screen?.frame(at: frame.sourceTime.seconds),
                                         camera: camera?.frame(at: frame.sourceTime.seconds), cursorSet: doc.config.cursor.set)
        else { throw ExportError.writerFailed("render failed") }
        ImageIOHelpers.writePNG(img, to: URL(fileURLWithPath: args[2]))
        Output.emit(["image": .string(args[2]), "width": .number(Double(size.width)), "height": .number(Double(size.height))]) { args[2] }
    }

    static func info(_ args: [String]) async throws {
        guard let path = args.first else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: path)))
        let m = project.manifest
        let scene = project.document.scene
        let map = TimeMap(slices: scene.slices)
        func r2(_ v: Double) -> JSONValue { .number((v * 100).rounded() / 100) }
        func outputRanges(_ source: SourceRange) -> JSONValue {
            .array(map.outputRanges(for: source).map { ["from": r2($0.start.seconds), "to": r2($0.end.seconds)] })
        }
        let json: JSONValue = [
            "project": .string(path),
            "name": .string(project.document.name),
            "status": .string(m.status.rawValue),
            "target": .string(m.target.rawValue), "targetName": .string(m.targetName),
            "sourceDuration": r2(m.duration),
            "outputDuration": r2(map.duration),
            "sourceSize": ["width": .number(Double(project.sourcePixelSize.width)), "height": .number(Double(project.sourcePixelSize.height))],
            "aspect": .string(project.document.config.output.aspect.rawValue),
            "channels": .array(m.channels.map { .string($0.kind.rawValue) }),
            "events": ["moves": .number(Double(project.events.moves.count)), "clicks": .number(Double(project.events.downClicks.count)),
                       "keys": .number(Double(project.events.keys.count)), "marks": .number(Double(project.bundle.loadMarks().count))],
            "clips": .array(scene.slices.map { ["source": ["from": r2($0.source.start.seconds), "to": r2($0.source.end.seconds)], "speed": r2($0.speed)] }),
            "zooms": .array(scene.zooms.map { ["output": outputRanges($0.source), "level": r2($0.level), "auto": .bool($0.isAuto)] }),
            "captions": .array(scene.captions.map { ["output": outputRanges($0.source), "text": .string($0.text)] }),
            "cuts": .array(zip(scene.slices, scene.slices.dropFirst()).compactMap { a, b in
                b.source.start.seconds - a.source.end.seconds > 0.01
                    ? ["source": ["from": r2(a.source.end.seconds), "to": r2(b.source.start.seconds)]] : nil }),
        ]
        Output.emit(json) {
            """
            name:      \(project.document.name)
            status:    \(m.status.rawValue)   target: \(m.target.rawValue) (\(m.targetName))
            duration:  \(String(format: "%.2f", m.duration))s   source: \(Int(project.sourcePixelSize.width))×\(Int(project.sourcePixelSize.height))
            channels:  \(m.channels.map(\.kind.rawValue).joined(separator: ", "))
            events:    \(project.events.moves.count) moves, \(project.events.downClicks.count) clicks, \(project.events.keys.count) keys, \(project.events.cursors.count) cursors
            edit:      \(scene.slices.count) clips, \(scene.zooms.count) zooms, \(scene.captions.count) captions, output \(String(format: "%.2f", map.duration))s
            """
        }
    }
}

extension Optional {
    func map<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        switch self {
        case let .some(v): return try await transform(v)
        case .none: return nil
        }
    }
}
