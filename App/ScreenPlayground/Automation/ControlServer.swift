import AppKit
import Capture
import Foundation
import PlaygroundCore

/// Answers `pgctl` and agents over a private Unix socket (see `Control` in PlaygroundCore).
///
/// Each connection gets its own thread for blocking I/O; commands run on the main actor.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()

    private var listener: LineSocket?
    let socketURL: URL

    init(socketURL: URL = Control.socketURL(forBundleID: Bundle.main.bundleIdentifier ?? Control.releaseBundleID)) {
        self.socketURL = socketURL
    }

    func start() {
        do {
            let listener = try LineSocket.listen(at: socketURL)
            self.listener = listener
            let thread = Thread { [weak self] in self?.acceptLoop(listener) }
            thread.name = "ScreenPlayground.ControlServer"
            thread.start()
        } catch {
            NSLog("Control server unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.close()
        unlink(socketURL.path)
    }

    private func acceptLoop(_ listener: LineSocket) {
        while let client = listener.accept() {
            let thread = Thread { Self.serve(client) }
            thread.name = "ScreenPlayground.ControlClient"
            thread.start()
        }
    }

    private static func serve(_ client: LineSocket) {
        defer { client.close() }
        while let line = client.readLine() {
            let response: ControlResponse
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                response = blockingDispatch(request)
            } else {
                response = .failure(ControlError("bad-request", "Expected one JSON object per line: {\"cmd\": ..., \"args\": {...}}."))
            }
            let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false}"#.utf8)
            client.writeLine(data)
        }
    }

    /// Runs a command on the main actor and waits for it (we're on a connection thread).
    private static func blockingDispatch(_ request: ControlRequest) -> ControlResponse {
        final class Box: @unchecked Sendable { var response = ControlResponse.failure(ControlError("internal", "No response.")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do {
                box.response = .success(try await ControlCommands.handle(request))
            } catch let error as ControlError {
                box.response = .failure(error)
            } catch {
                box.response = .failure(ControlError("failed", error.localizedDescription))
            }
            done.signal()
        }
        done.wait()
        return box.response
    }
}

/// The command set. Results are plain JSON so any agent can read them.
@MainActor
enum ControlCommands {
    static var recorder: RecorderController { AppModel.shared.recorder }

    static func handle(_ request: ControlRequest) async throws -> JSONValue {
        let args = request.args
        switch request.cmd {
        case "ping": return ping()
        case "targets": return targets()
        case "record.start": return try await recordStart(args)
        case "record.stop": return try await recordStop(args)
        case "record.cancel": return try await recordCancel()
        case "record.status": return status()
        case "mark": return try mark(args)
        case "run": return try await run(args)
        default:
            throw ControlError("unknown-command", "Unknown command '\(request.cmd)'.",
                               fix: "Commands: ping, targets, run, record.start, record.stop, record.cancel, record.status, mark.")
        }
    }

    // MARK: Info

    static func ping() -> JSONValue {
        var permissions: [String: JSONValue] = [:]
        for p in Permission.allCases { permissions[p.rawValue] = .bool(PermissionCenter.isGranted(p)) }
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "app": "Screen Playground",
            "version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
            "bundleID": .string(Bundle.main.bundleIdentifier ?? ""),
            "permissions": .object(permissions),
            "projectsFolder": .string(AppModel.shared.projectsFolder.path),
            "recording": .bool(recorder.session != nil),
            "update": updateInfo(),
        ]
    }

    static func updateInfo() -> JSONValue {
        let u = UpdateChecker.shared
        switch u.state {
        case let .ready(feed, _): return ["available": true, "version": .string(feed.version), "ready": true]
        case let .downloading(feed, _): return ["available": true, "version": .string(feed.version), "ready": false]
        case let .failed(feed?, _): return ["available": true, "version": .string(feed.version), "ready": false]
        default: return ["available": false]
        }
    }

    static func targets() -> JSONValue {
        let displays = CaptureCatalog.displays().enumerated().map { i, d -> JSONValue in
            ["index": .number(Double(i + 1)), "id": .number(Double(d.id)), "name": .string(d.name), "frame": rect(d.frame)]
        }
        let windows = CaptureCatalog.windows().map { w -> JSONValue in
            ["id": .number(Double(w.id)), "app": .string(w.appName), "bundleID": w.bundleID.map { .string($0) } ?? .null,
             "title": .string(w.title), "frame": rect(w.frame)]
        }
        return ["displays": .array(displays), "windows": .array(windows)]
    }

    static func status() -> JSONValue {
        let state: String
        switch recorder.state {
        case .idle: state = "idle"
        case .picking: state = "picking"
        case .countdown: state = "countdown"
        case .recording: state = "recording"
        case .finishing: state = "finishing"
        }
        return [
            "state": .string(state),
            "elapsed": .number(recorder.session == nil ? 0 : recorder.elapsed),
            "paused": .bool(recorder.isPaused),
            "project": recorder.session.map { .string($0.bundle.url.path) } ?? .null,
            "lastFinished": recorder.lastFinished.map { .string($0.path) } ?? .null,
        ]
    }

    // MARK: Recording

    static func recordStart(_ args: JSONValue) async throws -> JSONValue {
        let target = try resolveTarget(args)
        var options = RecorderController.AutomationOptions()
        options.countdown = max(0, args["countdown"]?.int ?? 0)
        options.maxDuration = args["maxDuration"]?.number
        options.name = args["name"]?.string
        options.openEditor = args["openEditor"]?.bool ?? false
        if let folder = args["folder"]?.string {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            options.folder = url
        }
        options.systemAudio = args["systemAudio"]?.bool ?? false
        options.cutIdle = args["cutIdle"]?.number
        if let mic = args["mic"] {
            if mic.bool == true {
                guard let first = CaptureCatalog.microphones().first else {
                    throw ControlError("no-microphone", "No microphone is available.")
                }
                options.microphoneID = first.id
            } else if let name = mic.string {
                guard let match = CaptureCatalog.microphones().first(where: { $0.id == name || $0.name.localizedCaseInsensitiveContains(name) }) else {
                    throw ControlError("no-microphone", "No microphone matches '\(name)'.")
                }
                options.microphoneID = match.id
            }
        }
        let url = try await recorder.startAutomated(target: target.target, options: options)
        return ["project": .string(url.path), "target": target.description]
    }

    static func recordStop(_ args: JSONValue) async throws -> JSONValue {
        let openEditor = args["openEditor"]?.bool ?? false
        let bundle: ProjectBundle
        if recorder.state == .recording {
            bundle = try await recorder.finish(openEditor: openEditor)
        } else if recorder.state == .finishing {
            // Stopped by a person or by maxDuration a moment ago; wait for it to land.
            while recorder.state == .finishing { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let url = recorder.lastFinished else { throw ControlError("not-recording", "Nothing is being recorded.") }
            bundle = ProjectBundle(url: url)
        } else if let url = recorder.lastFinished, args["allowFinished"]?.bool ?? true {
            bundle = ProjectBundle(url: url)
        } else {
            throw ControlError("not-recording", "Nothing is being recorded.", fix: "Start one with `pgctl record start`.")
        }
        return try summary(bundle)
    }

    static func recordCancel() async throws -> JSONValue {
        guard recorder.session != nil else { throw ControlError("not-recording", "Nothing is being recorded.") }
        recorder.deleteRecording()
        while recorder.state != .idle { try await Task.sleep(nanoseconds: 50_000_000) }
        return ["cancelled": true]
    }

    static func mark(_ args: JSONValue) throws -> JSONValue {
        guard let raw = args["kind"]?.string, let kind = RecordingMark.Kind(rawValue: raw) else {
            let kinds = RecordingMark.Kind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ControlError("bad-request", "mark needs a kind: \(kinds).")
        }
        if kind == .caption, (args["text"]?.string ?? "").isEmpty {
            throw ControlError("bad-request", "A caption mark needs text.")
        }
        let t = try recorder.addMark(kind, text: args["text"]?.string, value: args["value"]?.number)
        return ["t": .number(t), "kind": .string(kind.rawValue)]
    }

    // MARK: Demo scripts

    static func run(_ args: JSONValue) async throws -> JSONValue {
        guard let raw = args["script"] else { throw ControlError("bad-request", "run needs a script.") }
        let script = try DemoScript.decode(JSONEncoder().encode(raw))
        let folder = args["folder"]?.string.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return try await DemoRunner(script: script).run(outputOverride: args["output"]?.string, openEditor: args["openEditor"]?.bool,
                                                        folder: folder)
    }

    // MARK: Helpers

    static func summary(_ bundle: ProjectBundle) throws -> JSONValue {
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: bundle.manifestFile))
        let events = bundle.loadEvents()
        let doc = try? bundle.loadDocument()
        return [
            "project": .string(bundle.url.path),
            "duration": .number((manifest.duration * 100).rounded() / 100),
            "clicks": .number(Double(events.downClicks.count)),
            "keys": .number(Double(events.keys.count)),
            "marks": .number(Double(bundle.loadMarks().count)),
            "zooms": .number(Double(doc?.scene.zooms.count ?? 0)),
        ]
    }

    static func rect(_ r: CGRect) -> JSONValue {
        ["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)]
    }

    struct ResolvedTarget {
        var target: RecordingTarget
        var description: JSONValue
    }

    /// `{"display": 1|id}` · `{"window": id}` · `{"app": "Safari"|"com.apple.Safari", "title": "…"}` ·
    /// `{"area": {"x","y","width","height"}}` (global points). Defaults to the main display.
    static func resolveTarget(_ args: JSONValue) throws -> ResolvedTarget {
        let displays = CaptureCatalog.displays()
        if let id = args["window"]?.int {
            guard let w = CaptureCatalog.windows().first(where: { $0.id == CGWindowID(id) }) else {
                throw ControlError("target-not-found", "No on-screen window with id \(id).", fix: "Run `pgctl targets` to list windows.")
            }
            return ResolvedTarget(target: .window(w.id), description: ["window": .number(Double(w.id)), "app": .string(w.appName), "title": .string(w.title)])
        }
        if let app = args["app"]?.string {
            let title = args["title"]?.string
            let candidates = CaptureCatalog.windows().filter {
                ($0.bundleID?.caseInsensitiveCompare(app) == .orderedSame || $0.appName.caseInsensitiveCompare(app) == .orderedSame)
                    && (title == nil || $0.title.localizedCaseInsensitiveContains(title!))
            }
            // Front-most first (the catalog is ordered front to back).
            guard let w = candidates.first else {
                throw ControlError("target-not-found", "No on-screen window for app '\(app)'\(title.map { " titled '\($0)'" } ?? "").",
                                   fix: "Open the app (and the window) first, or run `pgctl targets` to see what's on screen.")
            }
            return ResolvedTarget(target: .window(w.id), description: ["window": .number(Double(w.id)), "app": .string(w.appName), "title": .string(w.title)])
        }
        if let area = args["area"], let x = area["x"]?.number, let y = area["y"]?.number,
           let width = area["width"]?.number, let height = area["height"]?.number {
            let r = CGRect(x: x, y: y, width: width, height: height)
            guard r.width >= 20, r.height >= 20, let d = CaptureCatalog.display(containing: r) else {
                throw ControlError("target-not-found", "The area must be at least 20×20 points and on a display.")
            }
            return ResolvedTarget(target: .area(d.id, r), description: ["area": rect(r)])
        }
        let wanted = args["display"]?.int
        let display: DisplayInfo?
        if let wanted {
            display = (1...max(displays.count, 1)).contains(wanted) && wanted <= displays.count
                ? displays[wanted - 1] : displays.first { $0.id == CGDirectDisplayID(wanted) }
        } else {
            display = displays.first { CGDisplayIsMain($0.id) != 0 } ?? displays.first
        }
        guard let display else {
            throw ControlError("target-not-found", "No display \(wanted.map(String.init) ?? "").", fix: "Run `pgctl targets` to list displays.")
        }
        return ResolvedTarget(target: .display(display.id), description: ["display": .number(Double(display.id)), "name": .string(display.name)])
    }
}
