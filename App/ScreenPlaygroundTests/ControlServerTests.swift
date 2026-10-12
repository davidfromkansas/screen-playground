import CoreGraphics
import Foundation
import PlaygroundCore
@testable import Screen_Playground
import Testing

/// The agent control channel, end to end over a real Unix socket.
/// Recording runs only when this app already has Screen Recording permission (never prompting),
/// records a small screen area without mic or camera, and writes to a temp folder.
@MainActor
@Suite(.serialized)
struct ControlServerTests {
    static func makeServer() -> (ControlServer, URL) {
        // Short path: Unix socket paths are limited to 103 bytes.
        let url = URL(fileURLWithPath: "/tmp/pg-test-\(UUID().uuidString.prefix(8)).sock")
        let server = ControlServer(socketURL: url)
        server.start()
        return (server, url)
    }

    /// Sends one request from a background thread (the server answers on the main actor).
    static func send(_ url: URL, _ cmd: String, _ args: JSONValue = [:]) async throws -> ControlResponse {
        try await Task.detached {
            guard let socket = LineSocket.connect(to: url) else { throw ControlError("connect", "no server") }
            defer { socket.close() }
            socket.writeLine(try JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
            guard let line = socket.readLine() else { throw ControlError("eof", "no response") }
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        }.value
    }

    @Test func pingTargetsAndErrors() async throws {
        let (server, url) = Self.makeServer()
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600, "socket must be private to this user")

        let ping = try await Self.send(url, "ping")
        #expect(ping.ok)
        #expect(ping.result?["permissions"]?["screenRecording"] != nil)

        let targets = try await Self.send(url, "targets")
        #expect((targets.result?["displays"]?.array?.count ?? 0) >= 1)

        let unknown = try await Self.send(url, "nope")
        #expect(!unknown.ok)
        #expect(unknown.error?.code == "unknown-command")

        let stopIdle = try await Self.send(url, "record.stop", ["allowFinished": false])
        #expect(stopIdle.error?.code == "not-recording")

        let badMark = try await Self.send(url, "mark", ["kind": "caption"])
        #expect(badMark.error?.code == "bad-request")

        let missingApp = try await Self.send(url, "record.start", ["app": "No Such App 123"])
        #expect(missingApp.error?.code == "target-not-found")
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func recordAreaWithMarks() async throws {
        let (server, url) = Self.makeServer()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-ctl-\(UUID().uuidString)")
        let main = CGDisplayBounds(CGMainDisplayID())
        let area: JSONValue = ["x": .number(main.minX + 40), "y": .number(main.minY + 60), "width": 480, "height": 300]

        let start = try await Self.send(url, "record.start", ["area": area, "folder": .string(folder.path), "name": "agent-test"])
        #expect(start.ok, "\(start.error?.message ?? "")")
        let project = try #require(start.result?["project"]?.string)
        #expect(project.hasPrefix(folder.path))

        let busy = try await Self.send(url, "record.start", ["area": area, "folder": .string(folder.path)])
        #expect(busy.error?.code == "busy")

        try await Task.sleep(nanoseconds: 600_000_000)
        let mark = try await Self.send(url, "mark", ["kind": "caption", "text": "Hello from an agent"])
        #expect(mark.ok)
        let status = try await Self.send(url, "record.status")
        #expect(status.result?["state"]?.string == "recording")
        try await Task.sleep(nanoseconds: 900_000_000)

        let stop = try await Self.send(url, "record.stop")
        #expect(stop.ok, "\(stop.error?.message ?? "")")
        #expect(stop.result?["project"]?.string == project)
        #expect((stop.result?["duration"]?.number ?? 0) > 1.2)
        #expect(stop.result?["marks"]?.int == 1)

        let bundle = ProjectBundle(url: URL(fileURLWithPath: project))
        let marks = bundle.loadMarks()
        #expect(marks.first?.kind == .caption)
        #expect(marks.first?.text == "Hello from an agent")
        #expect((marks.first?.t ?? 0) > 0.3)
        #expect(FileManager.default.fileExists(atPath: bundle.projectFile.path), "finalized into a project")
        try? FileManager.default.removeItem(at: folder)
    }
}
