import Foundation
import PlaygroundCore

/// Output for humans by default, or one JSON object on stdout with `--json` (for agents).
enum Output {
    nonisolated(unsafe) static var json = false

    static func emit(_ value: JSONValue, text: () -> String) {
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: (try? enc.encode(value)) ?? Data("null".utf8), as: UTF8.self))
        } else {
            print(text())
        }
    }

    static func fail(_ error: Error) -> Never {
        let e = error as? ControlError ?? ControlError("failed", error.localizedDescription)
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let body: JSONValue = ["error": ["code": .string(e.code), "message": .string(e.message), "fix": e.fix.map { .string($0) } ?? .null]]
            print(String(decoding: (try? enc.encode(body)) ?? Data(), as: UTF8.self))
        } else {
            FileHandle.standardError.write(Data("error: \(e.message)\n".utf8))
            if let fix = e.fix { FileHandle.standardError.write(Data("  fix: \(fix)\n".utf8)) }
        }
        exit(1)
    }
}

/// Commands that drive the running app (recording, marks).
enum LiveCommands {
    static func status() throws {
        let r = try ControlClient.send("ping")
        Output.emit(r) {
            let perms = r["permissions"].flatMap { v -> String? in
                guard case let .object(o) = v else { return nil }
                return o.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.bool == true ? "✓" : "✗")" }.joined(separator: "  ")
            } ?? ""
            return """
            Screen Playground \(r["version"]?.string ?? "?") — \(r["recording"]?.bool == true ? "recording" : "ready")
            permissions: \(perms)
            projects:    \(r["projectsFolder"]?.string ?? "")
            """
        }
    }

    static func targets() throws {
        let r = try ControlClient.send("targets")
        Output.emit(r) {
            var lines = ["Displays:"]
            for d in r["displays"]?.array ?? [] {
                lines.append("  --display \(d["index"]?.int ?? 0)   \(d["name"]?.string ?? "")  \(size(d["frame"]))")
            }
            lines.append("Windows (front to back):")
            for w in r["windows"]?.array ?? [] {
                let title = w["title"]?.string ?? ""
                lines.append("  --window \(w["id"]?.int ?? 0)   \(w["app"]?.string ?? "")\(title.isEmpty ? "" : " — \(title)")  \(size(w["frame"]))")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func record(_ args: [String]) throws {
        guard let sub = args.first else { PGCtl.usage() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "start":
            var a: [String: JSONValue] = [:]
            if let v = PGCtl.option(rest, "--display").flatMap(Int.init) { a["display"] = .number(Double(v)) }
            if let v = PGCtl.option(rest, "--window").flatMap(Int.init) { a["window"] = .number(Double(v)) }
            if let v = PGCtl.option(rest, "--app") { a["app"] = .string(v) }
            if let v = PGCtl.option(rest, "--title") { a["title"] = .string(v) }
            if let v = PGCtl.option(rest, "--area") {
                let p = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard p.count == 4 else { throw ControlError("bad-request", "--area wants x,y,width,height in screen points.") }
                a["area"] = ["x": .number(p[0]), "y": .number(p[1]), "width": .number(p[2]), "height": .number(p[3])]
            }
            if rest.contains("--mic") {
                let next = PGCtl.option(rest, "--mic")
                a["mic"] = next.map { $0.hasPrefix("--") ? .bool(true) : .string($0) } ?? .bool(true)
            }
            if rest.contains("--system-audio") { a["systemAudio"] = true }
            if let v = PGCtl.option(rest, "--countdown").flatMap(Int.init) { a["countdown"] = .number(Double(v)) }
            if let v = PGCtl.option(rest, "--max-duration").flatMap(Double.init) { a["maxDuration"] = .number(v) }
            if let v = PGCtl.option(rest, "--name") { a["name"] = .string(v) }
            if let v = PGCtl.option(rest, "--folder") {
                a["folder"] = .string(URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL.path)
            }
            if rest.contains("--open-editor") { a["openEditor"] = true }
            if let v = PGCtl.option(rest, "--cut-idle").flatMap(Double.init) { a["cutIdle"] = .number(v) }
            let r = try ControlClient.send("record.start", .object(a))
            Output.emit(r) { "recording → \(r["project"]?.string ?? "")\nstop with: pgctl record stop" }
        case "stop":
            let r = try ControlClient.send("record.stop", ["openEditor": .bool(rest.contains("--open-editor"))])
            Output.emit(r) {
                "saved \(r["project"]?.string ?? "")\n\(r["duration"]?.number.map { String(format: "%.1f", $0) } ?? "?")s · "
                    + "\(r["clicks"]?.int ?? 0) clicks · \(r["zooms"]?.int ?? 0) zooms · \(r["marks"]?.int ?? 0) marks"
            }
        case "cancel":
            let r = try ControlClient.send("record.cancel")
            Output.emit(r) { "recording discarded" }
        case "status":
            let r = try ControlClient.send("record.status")
            Output.emit(r) {
                let state = r["state"]?.string ?? "?"
                guard state == "recording" else { return state }
                return "recording \(String(format: "%.1f", r["elapsed"]?.number ?? 0))s → \(r["project"]?.string ?? "")"
            }
        default: PGCtl.usage()
        }
    }

    /// `pgctl mark caption "text" [--for 3]` · `pgctl mark zoom [2.0]` · `pgctl mark cut-start|cut-end|hold|note [text]`
    static func mark(_ args: [String]) throws {
        guard let kind = args.first else { PGCtl.usage() }
        var a: [String: JSONValue] = ["kind": .string(kind)]
        let free = args.dropFirst().prefix { !$0.hasPrefix("--") }.joined(separator: " ")
        if let n = Double(free) { a["value"] = .number(n) } else if !free.isEmpty { a["text"] = .string(free) }
        if let v = PGCtl.option(args, "--for").flatMap(Double.init) { a["value"] = .number(v) }
        if let v = PGCtl.option(args, "--level").flatMap(Double.init) { a["value"] = .number(v) }
        if let v = PGCtl.option(args, "--speed").flatMap(Double.init) { a["value"] = .number(v) }
        let r = try ControlClient.send("mark", .object(a))
        Output.emit(r) { "\(kind) at \(String(format: "%.2f", r["t"]?.number ?? 0))s" }
    }

    /// `pgctl run demo.json [--check] [--output file.mp4] [--open-editor] [--folder DIR]`
    static func run(_ args: [String]) throws {
        guard let path = args.first, !path.hasPrefix("--") else { PGCtl.usage() }
        let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                               : try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let script = try DemoScript.decode(data)
        if args.contains("--check") {
            Output.emit(["ok": true, "steps": .number(Double(script.steps.count)), "app": .string(script.target.app)]) {
                "script OK: \(script.steps.count) steps in \(script.target.app)"
            }
            return
        }
        var a: [String: JSONValue] = ["script": try JSONValue.from(script)]
        if let v = PGCtl.option(args, "--output") {
            a["output"] = .string(URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL.path)
        }
        if let v = PGCtl.option(args, "--folder") {
            a["folder"] = .string(URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL.path)
        }
        if args.contains("--open-editor") { a["openEditor"] = true }
        FileHandle.standardError.write(Data("running \(script.steps.count) steps in \(script.target.app) — press Esc to stop\n".utf8))
        let r = try ControlClient.send("run", .object(a))
        Output.emit(r) {
            var lines = ["recorded \(r["project"]?.string ?? "")"]
            if let out = r["output"]?.string { lines.append("exported \(out)") }
            lines.append(String(format: "%.1fs · %d zooms · %d captions", r["duration"]?.number ?? 0, r["zooms"]?.int ?? 0, r["captions"]?.int ?? 0))
            for w in r["warnings"]?.array ?? [] { lines.append("warning: \(w.string ?? "")") }
            return lines.joined(separator: "\n")
        }
    }

    private static func size(_ frame: JSONValue?) -> String {
        guard let w = frame?["width"]?.int, let h = frame?["height"]?.int else { return "" }
        return "(\(w)×\(h))"
    }
}
