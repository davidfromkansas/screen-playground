import AppKit
import Foundation
import PlaygroundCore

/// Talks to the running Screen Playground app over its control socket, launching it if needed.
enum ControlClient {
    static func send(_ cmd: String, _ args: JSONValue = [:]) throws -> JSONValue {
        let socket = try connect()
        defer { socket.close() }
        socket.writeLine(try JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
        guard let line = socket.readLine() else {
            throw ControlError("no-response", "Screen Playground closed the connection.")
        }
        let response = try JSONDecoder().decode(ControlResponse.self, from: line)
        if let error = response.error { throw error }
        return response.result ?? .null
    }

    private static func connect() throws -> LineSocket {
        let url = Control.socketURL
        if let s = LineSocket.connect(to: url) { return s }
        // A custom socket means a specific (test) app instance: don't launch the installed one.
        guard ProcessInfo.processInfo.environment["PG_CONTROL_SOCKET"] == nil else {
            throw ControlError("app-not-running", "Nothing is listening on \(url.path).")
        }
        try launchApp()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let s = LineSocket.connect(to: url) { return s }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ControlError("app-not-running", "Screen Playground didn't start answering within 15 seconds.",
                           fix: "Open Screen Playground once by hand (it may be waiting on a permission prompt), then retry.")
    }

    /// Opens the app in the background without its Home window.
    private static func launchApp() throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Control.releaseBundleID) ?? bundledAppURL() else {
            throw ControlError("app-not-installed", "Screen Playground isn't installed.",
                               fix: "Download it from https://www.davidfromkansas.com/screenplayground/ and move it to Applications.")
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", appURL.path, "--args", "-PGNoHome", "YES"]
        try open.run()
        open.waitUntilExit()
    }

    /// When pgctl runs from inside the app bundle (Contents/Helpers/pgctl), that bundle.
    private static func bundledAppURL() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}
