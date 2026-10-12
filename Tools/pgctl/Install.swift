import AppKit
import Foundation
import PlaygroundCore

/// `pgctl install [--for claude-code|claude-desktop|codex]`: puts pgctl on PATH (a symlink in ~/.local/bin,
/// no admin needed) and connects it to an agent app.
enum Installer {
    /// The home folder, or `PG_HOME` (tests never touch the real config files).
    static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["PG_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.local/bin`, or `PG_INSTALL_DIR` (tests).
    static var binFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["PG_INSTALL_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var me: URL { URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath() }

    /// The app bundle this pgctl belongs to (inside it, next to it in a build folder, or the installed app).
    static func appBundle() -> URL? {
        let fm = FileManager.default
        if me.path.contains(".app/Contents/MacOS/") {
            return me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        let sibling = me.deletingLastPathComponent().appendingPathComponent("Screen Playground.app")
        if fm.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Control.releaseBundleID)
    }

    /// The pgctl to link to: the one inside the app, so updating the app updates the tool.
    static func toolURL() -> URL {
        if me.path.contains(".app/Contents/MacOS/") { return me }
        if let app = appBundle() {
            let bundled = app.appendingPathComponent("Contents/MacOS/pgctl")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        return me
    }

    static func skillText() throws -> String {
        if let path = ProcessInfo.processInfo.environment["PG_SKILL_PATH"] { return try String(contentsOfFile: path, encoding: .utf8) }
        guard let app = appBundle() else {
            throw ControlError("app-not-installed", "Couldn't find Screen Playground to copy the skill from.")
        }
        return try String(contentsOf: app.appendingPathComponent("Contents/Resources/SKILL.md"), encoding: .utf8)
    }

    // MARK: Command line tool

    static func installCLI(force: Bool) throws -> JSONValue {
        let fm = FileManager.default
        let source = toolURL()
        let link = binFolder.appendingPathComponent("pgctl")
        try fm.createDirectory(at: binFolder, withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing != source.path { try fm.removeItem(at: link) }
        } else if fm.fileExists(atPath: link.path) {
            guard force else {
                throw ControlError("exists", "\(link.path) exists and isn't a link to pgctl.", fix: "Re-run with --force to replace it.")
            }
            try fm.removeItem(at: link)
        }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let onPath = path.split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL == binFolder.standardizedFileURL }
        return [
            "installed": .string(link.path),
            "target": .string(source.path),
            "onPath": .bool(onPath),
            "pathHint": onPath ? .null : .string(#"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc"#),
        ]
    }

    // MARK: Agent apps

    /// Claude Code: the skill teaches it the workflow; it runs pgctl from its shell.
    static func installClaudeCode() throws -> JSONValue {
        let folder = home.appendingPathComponent(".claude/skills/screen-playground-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try skillText().write(to: file, atomically: true, encoding: .utf8)
        return ["skill": .string(file.path), "next": "Start a new Claude Code session and ask it to make a demo video."]
    }

    /// Claude desktop app (chat): an MCP server entry in claude_desktop_config.json (backed up first).
    static func installClaudeDesktop() throws -> JSONValue {
        let file = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ControlError("bad-config", "\(file.path) isn't a JSON object; not touching it.")
            }
            root = parsed
            try backup(file)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["screen-playground"] = ["command": toolURL().path, "args": ["mcp"]]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        return ["config": .string(file.path), "next": "Quit and reopen the Claude app; Screen Playground appears under its tools."]
    }

    /// Codex CLI / IDE: an MCP server entry in ~/.codex/config.toml (backed up first), plus AGENTS.md text.
    static func installCodex() throws -> JSONValue {
        let file = home.appendingPathComponent(".codex/config.toml")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let header = "[mcp_servers.screen-playground]"
        let entry = "\(header)\ncommand = \"\(toolURL().path)\"\nargs = [\"mcp\"]\n"
        if text.contains(header) {
            // Replace the existing block (up to the next table header).
            var lines = text.components(separatedBy: "\n")
            if let start = lines.firstIndex(of: header) {
                var end = start + 1
                while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                lines.replaceSubrange(start..<end, with: entry.components(separatedBy: "\n"))
                text = lines.joined(separator: "\n")
            }
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + entry
        }
        if FileManager.default.fileExists(atPath: file.path) { try backup(file) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let agents = home.appendingPathComponent(".codex/screen-playground-AGENTS.md")
        try skillText().write(to: agents, atomically: true, encoding: .utf8)
        return ["config": .string(file.path), "agentsSnippet": .string(agents.path),
                "next": .string("Restart Codex. To teach a project the workflow, paste \(agents.lastPathComponent) into its AGENTS.md.")]
    }

    static func backup(_ file: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).bak-\(stamp)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: file, to: copy)
    }

    static func run(_ args: [String]) throws {
        var result: [String: JSONValue] = [:]
        if case let .object(cli) = try installCLI(force: args.contains("--force")) { result = cli }
        let targets = PGCtl.options(args, "--for")
        for target in targets {
            switch target {
            case "claude-code": result["claudeCode"] = try installClaudeCode()
            case "claude-desktop": result["claudeDesktop"] = try installClaudeDesktop()
            case "codex": result["codex"] = try installCodex()
            default: throw ControlError("bad-request", "Unknown --for \(target).", fix: "Use claude-code, claude-desktop or codex.")
            }
        }
        let value = JSONValue.object(result)
        Output.emit(value) {
            var text = "linked \(result["installed"]?.string ?? "") → \(result["target"]?.string ?? "")"
            if let hint = result["pathHint"]?.string {
                text += "\n~/.local/bin isn't on your PATH yet. Add it with:\n  \(hint)"
            }
            for key in ["claudeCode", "claudeDesktop", "codex"] {
                guard let r = result[key] else { continue }
                let where_ = r["skill"]?.string ?? r["config"]?.string ?? ""
                text += "\n\(key == "claudeCode" ? "Claude Code" : key == "claudeDesktop" ? "Claude app" : "Codex"): \(where_)\n  \(r["next"]?.string ?? "")"
            }
            return text
        }
    }
}
