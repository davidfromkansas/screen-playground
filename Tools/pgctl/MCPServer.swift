import Foundation
import PlaygroundCore

/// `pgctl mcp`: a Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0), for agent
/// apps without a shell (the Claude app's chat, Codex via MCP). Each tool runs `pgctl --json …` as a
/// subprocess, so the CLI stays the single implementation; `render_frames` returns the contact sheet as
/// an image the model can look at.
enum MCPServer {
    static let instructions = """
    Screen Playground records polished demo videos on this Mac. Typical flow: demo_status → run_demo (a script \
    of clicks/typing with captions; the app drives the real cursor while recording) → render_frames to look at \
    the result → edit_project to adjust captions/zooms/cuts → export. Keep demos 15–45 s with short captions. \
    Before run_demo, tell the user their cursor will move on its own (Esc stops it). Use test data only; \
    password fields are refused.
    """

    // MARK: Tools

    struct Tool: Sendable {
        var name: String
        var description: String
        var schema: JSONValue
        var args: @Sendable (JSONValue) throws -> [String]
        var image: Bool = false
    }

    static func str(_ v: JSONValue?, _ name: String) throws -> String {
        guard let s = v?.string, !s.isEmpty else { throw ControlError("bad-request", "\(name) is required.") }
        return s
    }

    static func num(_ v: JSONValue?) -> String? { v?.number.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } }

    static let tools: [Tool] = [
        Tool(name: "demo_status", description: "Screen Playground version and whether Screen Recording and Accessibility are allowed.",
             schema: ["type": "object", "properties": [:]], args: { _ in ["status"] }),
        Tool(name: "list_targets", description: "Displays and windows that can be recorded (front to back).",
             schema: ["type": "object", "properties": [:]], args: { _ in ["targets"] }),
        Tool(name: "run_demo",
             description: """
             Record a demo: opens the target app/URL, records its window while performing the steps with a real, \
             smoothly animated cursor and natural typing, then auto-zooms on clicks, adds captions and cuts idle time. \
             Script format: {"target": {"app": "Safari", "url": "http://localhost:3000", "windowSize": [1280, 800]}, \
             "steps": [{"click": "Sign up", "caption": "Start here"}, {"type": {"into": {"label": "Email"}, "text": "a@example.com", "speed": 2}}, \
             {"click": {"text": "Create", "role": "button"}, "zoom": 2}, {"key": "cmd+k"}, {"scroll": "down"}, {"wait": 1.5}], \
             "style": {"aspect": "16:9"}, "options": {"cutIdle": 1.5}}. Each step has exactly one action \
             (click/doubleClick/rightClick/hover/type/key/scroll/wait) plus optional caption, zoom (1.1–4), hold (seconds). \
             Targets: visible text, {"label": "Field"}, {"text", "role", "index"}, or {"point": [x, y]}. Takes as long as the demo.
             """,
             schema: ["type": "object", "required": ["script"], "properties": [
                 "script": ["type": "object", "description": "The demo script."],
                 "output": ["type": "string", "description": "Optional .mp4/.gif/.mov path to export to."],
             ]],
             args: { a in
                 guard let script = a["script"] else { throw ControlError("bad-request", "script is required.") }
                 let file = FileManager.default.temporaryDirectory.appendingPathComponent("pgctl-mcp-\(UUID().uuidString).json")
                 try JSONEncoder().encode(script).write(to: file)
                 var args = ["run", file.path]
                 if let out = a["output"]?.string { args += ["--output", out] }
                 return args
             }),
        Tool(name: "record_start", description: "Start recording without a script (free mode). Then act with your own tools, add marks, and call record_stop.",
             schema: ["type": "object", "properties": [
                 "app": ["type": "string", "description": "Record this app's front window (name or bundle ID)."],
                 "title": ["type": "string"], "window": ["type": "number"], "display": ["type": "number"],
                 "cut_idle": ["type": "number", "description": "Cut idle stretches longer than this many seconds."],
             ]],
             args: { a in
                 var r = ["record", "start"]
                 if let v = a["app"]?.string { r += ["--app", v] }
                 if let v = a["title"]?.string { r += ["--title", v] }
                 if let v = num(a["window"]) { r += ["--window", v] }
                 if let v = num(a["display"]) { r += ["--display", v] }
                 if let v = num(a["cut_idle"]) { r += ["--cut-idle", v] }
                 return r
             }),
        Tool(name: "mark", description: "While recording: caption (text), zoom (value = level), cut-start/cut-end, speed-start (value)/speed-end, hold (value = seconds).",
             schema: ["type": "object", "required": ["kind"], "properties": [
                 "kind": ["type": "string", "enum": ["caption", "zoom", "cut-start", "cut-end", "speed-start", "speed-end", "hold", "note"]],
                 "text": ["type": "string"], "value": ["type": "number"],
             ]],
             args: { a in
                 var r = ["mark", try str(a["kind"], "kind")]
                 if let t = a["text"]?.string { r.append(t) }
                 if let v = num(a["value"]) { r.append(v) }
                 return r
             }),
        Tool(name: "record_stop", description: "Finish the recording; returns the project path.",
             schema: ["type": "object", "properties": [:]], args: { _ in ["record", "stop"] }),
        Tool(name: "project_info", description: "Duration, clips, zooms, captions and cuts of a project (times in the edited video).",
             schema: ["type": "object", "required": ["project"], "properties": ["project": ["type": "string"]]],
             args: { a in ["info", try str(a["project"], "project")] }),
        Tool(name: "render_frames", description: "Render frames of the edited video and return a contact sheet image to review.",
             schema: ["type": "object", "required": ["project"], "properties": [
                 "project": ["type": "string"], "every": ["type": "number", "description": "Seconds between frames."],
             ]],
             args: { a in
                 var r = ["frames", try str(a["project"], "project")]
                 if let v = num(a["every"]) { r += ["--every", v] }
                 return r
             }, image: true),
        Tool(name: "edit_project",
             description: "Change a project and save it. Times are seconds in the edited video. Captions/zooms/cuts are added on top of what's there.",
             schema: ["type": "object", "required": ["project"], "properties": [
                 "project": ["type": "string"],
                 "captions": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "number"], "to": ["type": "number"], "text": ["type": "string"]]]],
                 "zooms": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "number"], "to": ["type": "number"],
                           "level": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"]]]],
                 "cuts": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "number"], "to": ["type": "number"]]]],
                 "speed": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "number"], "to": ["type": "number"], "speed": ["type": "number"]]]],
                 "cut_idle": ["type": "number"], "aspect": ["type": "string"], "preset": ["type": "string", "description": "Preset file path."],
                 "clear_captions": ["type": "boolean"], "clear_zooms": ["type": "boolean"],
             ]],
             args: { a in
                 var r = ["edit", try str(a["project"], "project"), "--output-time"]
                 if a["clear_captions"]?.bool == true { r.append("--clear-captions") }
                 if a["clear_zooms"]?.bool == true { r.append("--clear-zooms") }
                 for c in a["captions"]?.array ?? [] {
                     r += ["--caption", "\(num(c["from"]) ?? "0"):\(num(c["to"]) ?? "0"):\(c["text"]?.string ?? "")"]
                 }
                 for z in a["zooms"]?.array ?? [] {
                     var spec = "\(num(z["from"]) ?? "0"):\(num(z["to"]) ?? "0"):\(num(z["level"]) ?? "2")"
                     if let x = num(z["x"]), let y = num(z["y"]) { spec += ":\(x),\(y)" }
                     r += ["--zoom", spec]
                 }
                 for c in a["cuts"]?.array ?? [] { r += ["--cut", "\(num(c["from"]) ?? "0"):\(num(c["to"]) ?? "0")"] }
                 for s in a["speed"]?.array ?? [] { r += ["--speed", "\(num(s["from"]) ?? "0"):\(num(s["to"]) ?? "0"):\(num(s["speed"]) ?? "2")"] }
                 if let v = num(a["cut_idle"]) { r += ["--cut-idle", v] }
                 if let v = a["aspect"]?.string { r += ["--aspect", v] }
                 if let v = a["preset"]?.string { r += ["--preset", v] }
                 return r
             }),
        Tool(name: "export", description: "Export a project to .mp4, .gif or .mov.",
             schema: ["type": "object", "required": ["project", "output"], "properties": [
                 "project": ["type": "string"], "output": ["type": "string"],
                 "res": ["type": "number", "enum": [720, 1080, 1440, 2160]], "fps": ["type": "number"],
                 "quality": ["type": "string", "enum": ["studio", "social", "web", "webLow"]], "aspect": ["type": "string"],
             ]],
             args: { a in
                 var r = ["export", try str(a["project"], "project"), (try str(a["output"], "output") as NSString).expandingTildeInPath]
                 if let v = num(a["res"]) { r += ["--res", v] }
                 if let v = num(a["fps"]) { r += ["--fps", v] }
                 if let v = a["quality"]?.string { r += ["--quality", v] }
                 if let v = a["aspect"]?.string { r += ["--aspect", v] }
                 return r
             }),
    ]

    // MARK: Protocol

    static func serve() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if let reply = handle(message) { send(reply) }
        }
        exit(0)
    }

    static func send(_ value: JSONValue) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(value) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    /// Returns the response for a request, or nil for notifications.
    static func handle(_ message: JSONValue) -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        let id = message["id"]
        guard let id, id != .null else { return nil } // notification (e.g. notifications/initialized)
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            let version = params["protocolVersion"]?.string ?? "2025-06-18"
            return reply(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "screen-playground", "version": .string(appVersion())],
                "instructions": .string(instructions),
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema] })])
        case "tools/call":
            guard let name = params["name"]?.string, let tool = tools.first(where: { $0.name == name }) else {
                return error(id, -32602, "Unknown tool.")
            }
            return reply(id, call(tool, params["arguments"] ?? [:]))
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    static func reply(_ id: JSONValue, _ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    /// Runs `pgctl --json <args>` and wraps its JSON as MCP tool content.
    static func call(_ tool: Tool, _ arguments: JSONValue) -> JSONValue {
        let args: [String]
        do { args = try tool.args(arguments) } catch {
            let e = error as? ControlError ?? ControlError("bad-request", error.localizedDescription)
            return ["content": [["type": "text", "text": .string(e.message)]], "isError": true]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        process.arguments = ["--json"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return ["content": [["type": "text", "text": .string("Couldn't run pgctl: \(error.localizedDescription)")]], "isError": true]
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if tool.name == "run_demo", let file = args.dropFirst().first { try? FileManager.default.removeItem(atPath: file) }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var content: [JSONValue] = [["type": "text", "text": .string(text.isEmpty ? "{}" : text)]]
        if tool.image, process.terminationStatus == 0,
           let json = try? JSONDecoder().decode(JSONValue.self, from: data), let sheet = json["contactSheet"]?.string,
           let image = try? Data(contentsOf: URL(fileURLWithPath: sheet)) {
            content.append(["type": "image", "data": .string(image.base64EncodedString()), "mimeType": "image/jpeg"])
        }
        return ["content": .array(content), "isError": .bool(process.terminationStatus != 0)]
    }

    static func appVersion() -> String {
        guard let app = Installer.appBundle(), let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let v = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return v
    }
}
