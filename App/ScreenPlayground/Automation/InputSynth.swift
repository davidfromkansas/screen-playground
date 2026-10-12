import AppKit
import CoreGraphics
import PlaygroundCore

/// Posts real mouse and keyboard events that look human: eased cursor glides, short dwells, natural typing.
/// Every event is tagged so the runner can tell its own input from a person's (who can abort with Esc).
@MainActor
final class InputSynth {
    static let marker: Int64 = 0x5350_4C47 // 'SPLG'

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var lastPosted: CGPoint?
    /// Checked between events; throwing stops the action immediately.
    var checkAbort: () throws -> Void = {}

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cghidEventTap)
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1e9))
        try checkAbort()
    }

    // MARK: Mouse

    /// Glides to `target` along a gentle arc with ease-in-out timing (duration grows with distance).
    func move(to target: CGPoint) async throws {
        let start = lastPosted ?? location
        let dx = target.x - start.x, dy = target.y - start.y
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 1 else { lastPosted = target; return }
        let duration = min(max(0.32 + dist / 2200, 0.32), 0.85)
        let steps = max(Int(duration * 120), 8)
        // Bow the path a little to one side, like a wrist movement.
        let bow = min(dist * 0.08, 60) * (dx >= 0 ? 1 : -1)
        let nx = -dy / dist, ny = dx / dist
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 // ease-in-out cubic
            let arc = sin(.pi * e) * bow
            let p = CGPoint(x: start.x + dx * e + nx * arc, y: start.y + dy * e + ny * arc)
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            lastPosted = p
            try await sleep(duration / Double(steps))
        }
    }

    func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1) async throws {
        try await move(to: p)
        try await sleep(0.12)
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for n in 1...count {
            let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(d)
            try await sleep(0.07)
            let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: button)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(u)
            if n < count { try await sleep(0.09) }
        }
    }

    func scroll(direction: String, lines: Double, at p: CGPoint) async throws {
        try await move(to: p)
        let total = lines * 40 // pixels
        let steps = max(Int(lines * 3), 6)
        for _ in 0..<steps {
            let amount = Int32(total / Double(steps))
            let (dy, dx): (Int32, Int32) = switch direction {
            case "up": (amount, 0)
            case "down": (-amount, 0)
            case "left": (0, amount)
            default: (0, -amount)
            }
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            try await sleep(0.02)
        }
    }

    // MARK: Keyboard

    func press(_ combo: KeyCombo) async throws {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: true)
        down?.flags = flags
        post(down)
        try await sleep(0.05)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: false)
        up?.flags = flags
        post(up)
        try await sleep(0.04)
    }

    /// Types text character by character at about `cps` characters per second, with a natural rhythm.
    func type(_ text: String, cps: Double) async throws {
        let base = 1 / max(cps, 2)
        for (i, ch) in text.enumerated() {
            if ch == "\n" {
                try await press(KeyCombo(keyCode: 36, modifiers: []))
                continue
            }
            let units = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(up)
            // Deterministic jitter (±35%) plus a beat after spaces and punctuation.
            let jitter = 0.65 + 0.7 * Double((i * 7919) % 100) / 100
            let pause = ch == " " || ch == "," || ch == "." ? base * 0.8 : 0
            try await sleep(base * jitter + pause)
        }
    }
}
