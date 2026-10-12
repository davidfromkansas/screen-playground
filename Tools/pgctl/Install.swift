import AppKit
import Foundation
import PlaygroundCore

/// `pgctl install`: puts pgctl on PATH (a symlink in ~/.local/bin, no admin needed).
enum Installer {
    /// `~/.local/bin`, or `PG_INSTALL_DIR` (tests).
    static var binFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["PG_INSTALL_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// The pgctl to link to: the one inside the installed app, so updates of the app update the tool.
    static func toolURL() -> URL {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if me.path.contains(".app/Contents/MacOS/") { return me }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Control.releaseBundleID) {
            let bundled = app.appendingPathComponent("Contents/MacOS/pgctl")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        return me
    }

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

    static func run(_ args: [String]) throws {
        let result = try installCLI(force: args.contains("--force"))
        Output.emit(result) {
            var text = "linked \(result["installed"]?.string ?? "") → \(result["target"]?.string ?? "")"
            if let hint = result["pathHint"]?.string {
                text += "\n~/.local/bin isn't on your PATH yet. Add it with:\n  \(hint)"
            }
            return text
        }
    }
}
