import ApplicationServices
import CoreGraphics
import Foundation
import PlaygroundCore
@testable import Screen_Playground
import Testing

/// Drives Safari with the real mouse and keyboard, so it only runs when asked:
/// `PG_UI_TESTS=1 xcodebuild test … -only-testing:ScreenPlaygroundTests/DemoRunnerTests`
/// Needs Screen Recording and Accessibility for this app. Uses a local test page, never real sites or accounts.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PG_UI_TESTS"] == "1"
    && CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()))
struct DemoRunnerTests {
    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Runner test page</title>
    <style>body{font:16px -apple-system;display:grid;place-items:center;height:100vh;margin:0}
    input,button{display:block;margin:8px 0;padding:8px;font-size:15px;width:260px}</style></head><body>
    <div id="f"><label for="team">Team name</label><input id="team" autocomplete="off">
    <label for="pw">Password</label><input id="pw" type="password" autocomplete="off">
    <button onclick="document.getElementById('f').hidden=true;document.getElementById('ok').hidden=false">Continue</button></div>
    <h1 id="ok" hidden>All set</h1></body></html>
    """

    static func pageURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("index.html")
        try page.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func script(_ json: String) throws -> DemoScript { try DemoScript.decode(Data(json.utf8)) }

    @Test func typesClicksAndFinalizes() async throws {
        let url = try Self.pageURL()
        let folder = url.deletingLastPathComponent()
        let s = try Self.script("""
        { "target": { "app": "Safari", "url": "\(url.absoluteString)", "windowSize": [900, 640] },
          "options": { "preRoll": 2 },
          "steps": [
            { "type": { "into": { "label": "Team name" }, "text": "Rocket" }, "caption": "Name your team" },
            { "click": "Continue", "zoom": 1.8 },
            { "wait": 1 } ] }
        """)
        let result = try await DemoRunner(script: s).run(folder: folder)
        #expect(result["steps"]?.array?.count == 3)
        let bundle = ProjectBundle(url: URL(fileURLWithPath: try #require(result["project"]?.string)))
        let doc = try bundle.loadDocument()
        #expect(doc.scene.captions.first?.text == "Name your team")
        #expect(bundle.loadEvents().downClicks.count >= 2, "clicked the field and the button")
        #expect(bundle.loadEvents().keys.count >= 6, "typed the team name")
    }

    @Test func refusesPasswordFields() async throws {
        let url = try Self.pageURL()
        let s = try Self.script("""
        { "target": { "app": "Safari", "url": "\(url.absoluteString)" }, "options": { "preRoll": 2 },
          "steps": [ { "type": { "into": { "label": "Password" }, "text": "nope" } } ] }
        """)
        do {
            _ = try await DemoRunner(script: s).run(folder: url.deletingLastPathComponent())
            Issue.record("typed into a password field")
        } catch let error as ControlError {
            #expect(error.code == "secure-field")
        }
    }
}
