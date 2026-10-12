import Foundation
import Testing
@testable import PlaygroundCore

@Suite struct DemoScriptTests {
    func decode(_ json: String) throws -> DemoScript { try DemoScript.decode(Data(json.utf8)) }

    func error(_ json: String) -> ControlError? {
        do { _ = try decode(json); return nil } catch { return error as? ControlError }
    }

    @Test func fullScriptWithShorthands() throws {
        let s = try decode("""
        {
          "target": { "app": "Safari", "url": "http://localhost:3000", "windowSize": [1280, 800] },
          "style": { "aspect": "16:9" },
          "options": { "cutIdle": 1.5 },
          "steps": [
            { "click": "Sign up", "caption": "Start here" },
            { "type": { "into": { "label": "Email" }, "text": "maya@example.com", "speed": 2 } },
            { "type": "hello" },
            { "click": { "text": "Create", "role": "button", "index": 2 }, "zoom": 2.5 },
            { "key": "cmd+shift+k" },
            { "scroll": "down" },
            { "scroll": { "direction": "up", "amount": 3, "at": { "point": [100, 200] } } },
            { "hover": { "label": "Search" } },
            { "wait": 1.5, "caption": "Done", "hold": 1 }
          ],
          "output": { "file": "~/Movies/x.mp4", "res": 1080 }
        }
        """)
        #expect(s.steps.count == 9)
        #expect(s.steps[0].action == .click(.init(text: "Sign up")))
        #expect(s.steps[0].caption == "Start here")
        guard case let .type(t) = s.steps[1].action else { Issue.record("not type"); return }
        #expect(t.into?.label == "Email" && t.speed == 2)
        #expect(s.steps[2].action == .type(.init(text: "hello")))
        #expect(s.steps[3].zoom == 2.5)
        #expect(s.steps[5].action == .scroll(.init(direction: "down")))
        #expect(s.steps[8].action == .wait(1.5))
        // Round-trips.
        let again = try JSONDecoder().decode(DemoScript.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test func helpfulErrors() {
        #expect(error(#"{"steps": [{"wait": 1}]}"#)?.message.contains("target") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": []}"#)?.message.contains("no steps") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"caption": "x"}]}"#)?.message.contains("needs one action") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"click": "a", "wait": 1}]}"#)?.message.contains("only have one action") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"click": {"role": "button"}}]}"#)?.message.contains("text, label or point") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"key": "cmd+banana"}]}"#)?.message.contains("unknown key") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"wait": 99}]}"#)?.message.contains("0…30") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"click": "a", "zoom": 9}]}"#)?.message.contains("zoom") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "style": {"aspect": "2:1"}, "steps": [{"wait": 1}]}"#)?.message.contains("aspect") == true)
        #expect(error(#"{"target": {"app": "Safari"}, "steps": [{"wait": 1}]}"#) == nil)
    }

    @Test func keyCombos() {
        #expect(KeyCombo.parse("cmd+k") == KeyCombo(keyCode: 40, modifiers: .command))
        #expect(KeyCombo.parse("Shift+Tab") == KeyCombo(keyCode: 48, modifiers: .shift))
        #expect(KeyCombo.parse("return")?.keyCode == 36)
        #expect(KeyCombo.parse("ctrl+opt+cmd+f5")?.modifiers == [.control, .option, .command])
        #expect(KeyCombo.parse("hyper+k") == nil)
        #expect(KeyCombo.parse("cmd+") == nil)
    }
}
