import PlaygroundCore

/// A keyboard shortcut worth showing on screen, with its keycap labels.
public struct ShortcutEvent: Hashable, Sendable {
    /// Source time of the key press.
    public var t: Double
    /// Index into the recording's keystrokes (for per-shortcut hiding).
    public var index: Int
    /// One label per keycap, in Apple's order: ⌃ ⌥ ⇧ ⌘ then the key.
    public var keys: [String]

    public init(t: Double, index: Int, keys: [String]) {
        self.t = t
        self.index = index
        self.keys = keys
    }

    public var text: String { keys.joined(separator: " ") }
}

/// Picks shortcuts out of raw keystrokes and formats them as keycaps.
public enum ShortcutDetector {
    /// How long a shortcut stays on screen.
    public static let displayDuration = 1.2

    static let special: [Int: String] = [
        36: "↩", 76: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Keys that are shortcuts on their own (when single keys are enabled).
    static let singleKeyCodes: Set<Int> = [36, 76, 48, 51, 117, 53, 123, 124, 125, 126, 115, 119, 116, 121]

    public static func detect(_ keys: [KeyStroke], includeSingleKeys: Bool, hidden: Set<Int> = []) -> [ShortcutEvent] {
        var out: [ShortcutEvent] = []
        for (i, k) in keys.enumerated() where !k.isRepeat && !hidden.contains(i) {
            let hasCommandLike = k.modifiers.contains(.command) || k.modifiers.contains(.control) || k.modifiers.contains(.option)
            let isSpecial = special[k.keyCode] != nil
            let shiftedSpecial = k.modifiers.contains(.shift) && isSpecial
            guard hasCommandLike || shiftedSpecial || (includeSingleKeys && (singleKeyCodes.contains(k.keyCode) || (k.keyCode >= 96 && isSpecial)))
            else { continue }
            var labels: [String] = []
            if k.modifiers.contains(.control) { labels.append("⌃") }
            if k.modifiers.contains(.option) { labels.append("⌥") }
            if k.modifiers.contains(.shift) { labels.append("⇧") }
            if k.modifiers.contains(.command) { labels.append("⌘") }
            if let name = special[k.keyCode] {
                labels.append(name)
            } else {
                let base = k.charactersIgnoringModifiers.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !base.isEmpty, base.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { continue }
                labels.append(base.uppercased())
            }
            out.append(ShortcutEvent(t: k.t, index: i, keys: labels))
        }
        return out
    }

    /// The shortcut visible at source time `t`, with its opacity (fades in and out).
    public static func active(_ shortcuts: [ShortcutEvent], at t: Double) -> (ShortcutEvent, Double)? {
        // Latest shortcut that started at or before t and is still within its display window.
        var lo = 0, hi = shortcuts.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if shortcuts[mid].t <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let s = shortcuts[found]
        let age = t - s.t
        guard age <= displayDuration else { return nil }
        let fadeIn = min(age / 0.08, 1), fadeOut = min((displayDuration - age) / 0.25, 1)
        return (s, max(0, min(fadeIn, fadeOut)))
    }
}
