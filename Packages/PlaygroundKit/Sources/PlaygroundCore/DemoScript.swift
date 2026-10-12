import Foundation

/// A demo an agent wants recorded: which window, what to do in it, and how the video should look.
///
/// ```json
/// {
///   "target": { "app": "Safari", "url": "http://localhost:3000", "windowSize": [1280, 800] },
///   "steps": [
///     { "click": "Sign up", "caption": "Start from the homepage" },
///     { "type": { "into": { "label": "Email" }, "text": "maya@example.com" } },
///     { "click": { "text": "Create account", "role": "button" }, "zoom": 2.2 },
///     { "wait": 1.5, "caption": "You're in" }
///   ],
///   "output": { "file": "~/Movies/signup.mp4" }
/// }
/// ```
public struct DemoScript: Codable, Sendable, Equatable {
    public var target: Target
    public var steps: [Step]
    public var style: Style?
    public var options: Options?
    public var output: OutputSpec?

    public struct Target: Codable, Sendable, Equatable {
        /// App name ("Safari") or bundle ID ("com.apple.Safari").
        public var app: String
        /// Opened in `app` before recording (web pages, documents).
        public var url: String?
        /// Pick the window whose title contains this.
        public var title: String?
        /// Resize the window (points) before recording, e.g. [1280, 800].
        public var windowSize: [Double]?
    }

    public struct Style: Codable, Sendable, Equatable {
        /// Name of a saved preset (Presets menu in the editor).
        public var preset: String?
        /// auto, 16:9, 9:16, 1:1, 4:3, 3:4, 4:5
        public var aspect: String?
    }

    public struct Options: Codable, Sendable, Equatable {
        /// Seconds to wait after opening the target, before recording starts (default 1.5 with a URL, else 0.5).
        public var preRoll: Double?
        /// Cut stretches with no input longer than this (default 1.5; 0 keeps everything).
        public var cutIdle: Double?
        /// Seconds to pause after each step (default 0.5).
        public var settle: Double?
        /// Typing pace in characters per second (default 14).
        public var typingSpeed: Double?
        /// Record the microphone (default false).
        public var microphone: Bool?
        /// Hard stop for the whole run in seconds (default 180).
        public var maxDuration: Double?
    }

    public struct OutputSpec: Codable, Sendable, Equatable {
        /// .mp4, .gif or .mov; the editor project is always kept as well.
        public var file: String?
        public var res: Int?
        public var fps: Int?
        /// studio, social, web, webLow
        public var quality: String?
        /// Open the project in the editor when done (default false).
        public var openEditor: Bool?
    }

    /// Finds an element in the target window's accessibility tree.
    public struct Locator: Codable, Sendable, Equatable {
        /// Visible text: a button title, link text, menu item, heading…
        public var text: String?
        /// A field's label or placeholder.
        public var label: String?
        /// Narrow by accessibility role: button, link, textField, checkbox, menuItem, tab…
        public var role: String?
        /// Which match when several fit (1-based, top-to-bottom order).
        public var index: Int?
        /// A point in window coordinates (points from the window's top-left), when nothing else works.
        public var point: [Double]?

        public init(text: String? = nil, label: String? = nil, role: String? = nil, index: Int? = nil, point: [Double]? = nil) {
            self.text = text
            self.label = label
            self.role = role
            self.index = index
            self.point = point
        }

        /// `"Sign up"` is shorthand for `{"text": "Sign up"}`.
        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(text: text)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(text: try c.decodeIfPresent(String.self, forKey: .text), label: try c.decodeIfPresent(String.self, forKey: .label),
                      role: try c.decodeIfPresent(String.self, forKey: .role), index: try c.decodeIfPresent(Int.self, forKey: .index),
                      point: try c.decodeIfPresent([Double].self, forKey: .point))
            guard text != nil || label != nil || point != nil else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "A target needs text, label or point.")
            }
            if let point, point.count != 2 {
                throw DecodingError.dataCorruptedError(forKey: .point, in: c, debugDescription: "point wants [x, y].")
            }
        }

        public var summary: String {
            if let text { return "\"\(text)\"" + (role.map { " (\($0))" } ?? "") }
            if let label { return "field \"\(label)\"" }
            if let point { return "point \(point)" }
            return "?"
        }
    }

    public struct TypeAction: Codable, Sendable, Equatable {
        public var text: String
        /// Click this field first.
        public var into: Locator?
        /// Select all and replace the field's contents.
        public var replace: Bool?
        /// Press Return afterwards.
        public var submit: Bool?
        /// Speed this typing up in the edit (e.g. 2 = twice as fast); typing itself stays natural.
        public var speed: Double?
    }

    public struct ScrollAction: Codable, Sendable, Equatable {
        /// up, down, left, right
        public var direction: String
        /// Roughly how many lines (default 5).
        public var amount: Double?
        /// Scroll with the pointer over this element (default: the window's centre).
        public var at: Locator?
    }

    public enum Action: Sendable, Equatable {
        case click(Locator)
        case doubleClick(Locator)
        case rightClick(Locator)
        case hover(Locator)
        case type(TypeAction)
        /// "cmd+k", "return", "shift+tab", "esc"
        case key(String)
        case scroll(ScrollAction)
        case wait(Double)

        public var name: String {
            switch self {
            case .click: "click"
            case .doubleClick: "doubleClick"
            case .rightClick: "rightClick"
            case .hover: "hover"
            case .type: "type"
            case .key: "key"
            case .scroll: "scroll"
            case .wait: "wait"
            }
        }
    }

    /// One action plus optional presentation hints.
    public struct Step: Codable, Sendable, Equatable {
        public var action: Action
        /// Caption shown from this step until the next caption.
        public var caption: String?
        /// Zoom level for the zoom around this step's click (e.g. 2.5).
        public var zoom: Double?
        /// Keep this many seconds after the step even if nothing moves (never idle-cut).
        public var hold: Double?

        enum CodingKeys: String, CodingKey {
            case click, doubleClick, rightClick, hover, type, key, scroll, wait, caption, zoom, hold
        }

        static let actionKeys: [CodingKeys] = [.click, .doubleClick, .rightClick, .hover, .type, .key, .scroll, .wait]

        public init(action: Action, caption: String? = nil, zoom: Double? = nil, hold: Double? = nil) {
            self.action = action
            self.caption = caption
            self.zoom = zoom
            self.hold = hold
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let present = Self.actionKeys.filter { c.contains($0) }
            guard present.count == 1, let key = present.first else {
                let names = Self.actionKeys.map(\.stringValue).joined(separator: ", ")
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                    debugDescription: present.isEmpty ? "Each step needs one action: \(names)."
                                                      : "A step can only have one action, found \(present.map(\.stringValue))."))
            }
            switch key {
            case .click: action = .click(try c.decode(Locator.self, forKey: key))
            case .doubleClick: action = .doubleClick(try c.decode(Locator.self, forKey: key))
            case .rightClick: action = .rightClick(try c.decode(Locator.self, forKey: key))
            case .hover: action = .hover(try c.decode(Locator.self, forKey: key))
            case .type:
                if let text = try? c.decode(String.self, forKey: key) {
                    action = .type(TypeAction(text: text))
                } else {
                    action = .type(try c.decode(TypeAction.self, forKey: key))
                }
            case .key: action = .key(try c.decode(String.self, forKey: key))
            case .scroll:
                if let direction = try? c.decode(String.self, forKey: key) {
                    action = .scroll(ScrollAction(direction: direction))
                } else {
                    action = .scroll(try c.decode(ScrollAction.self, forKey: key))
                }
            case .wait:
                let seconds = try c.decode(Double.self, forKey: key)
                guard seconds >= 0, seconds <= 30 else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "wait must be 0…30 seconds.")
                }
                action = .wait(seconds)
            default: fatalError("unreachable")
            }
            caption = try c.decodeIfPresent(String.self, forKey: .caption)
            zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
            hold = try c.decodeIfPresent(Double.self, forKey: .hold)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch action {
            case let .click(l): try c.encode(l, forKey: .click)
            case let .doubleClick(l): try c.encode(l, forKey: .doubleClick)
            case let .rightClick(l): try c.encode(l, forKey: .rightClick)
            case let .hover(l): try c.encode(l, forKey: .hover)
            case let .type(t): try c.encode(t, forKey: .type)
            case let .key(k): try c.encode(k, forKey: .key)
            case let .scroll(s): try c.encode(s, forKey: .scroll)
            case let .wait(w): try c.encode(w, forKey: .wait)
            }
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(zoom, forKey: .zoom)
            try c.encodeIfPresent(hold, forKey: .hold)
        }
    }

    /// Decodes a script with error messages that point at the problem (for agents to fix and retry).
    public static func decode(_ data: Data) throws -> DemoScript {
        do {
            let script = try JSONDecoder().decode(DemoScript.self, from: data)
            try script.validate()
            return script
        } catch let error as DecodingError {
            throw ControlError("bad-script", Self.describe(error),
                               fix: "See `pgctl help script` for the format.")
        }
    }

    public func validate() throws {
        guard !steps.isEmpty else { throw ControlError("bad-script", "The script has no steps.") }
        guard steps.count <= 200 else { throw ControlError("bad-script", "Keep scripts under 200 steps.") }
        if let size = target.windowSize, size.count != 2 || size[0] < 320 || size[1] < 240 {
            throw ControlError("bad-script", "target.windowSize wants [width, height] of at least [320, 240].")
        }
        if let aspect = style?.aspect, !["auto", "16:9", "9:16", "1:1", "4:3", "3:4", "4:5"].contains(aspect) {
            throw ControlError("bad-script", "style.aspect must be one of auto, 16:9, 9:16, 1:1, 4:3, 3:4, 4:5.")
        }
        for (i, step) in steps.enumerated() {
            if case let .key(combo) = step.action, KeyCombo.parse(combo) == nil {
                throw ControlError("bad-script", "Step \(i + 1): unknown key \"\(combo)\".", fix: "Use names like cmd+k, return, tab, esc, shift+tab, up, f5.")
            }
            if case let .scroll(s) = step.action, !["up", "down", "left", "right"].contains(s.direction) {
                throw ControlError("bad-script", "Step \(i + 1): scroll direction must be up, down, left or right.")
            }
            if let z = step.zoom, !(1.1...4).contains(z) {
                throw ControlError("bad-script", "Step \(i + 1): zoom must be between 1.1 and 4.")
            }
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ p: [CodingKey]) -> String {
            p.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case let .keyNotFound(key, ctx): return "Missing \"\(key.stringValue)\" at \(path(ctx.codingPath).isEmpty ? "the top level" : path(ctx.codingPath))."
        case let .typeMismatch(_, ctx), let .valueNotFound(_, ctx): return "Wrong type at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        case let .dataCorrupted(ctx): return (path(ctx.codingPath).isEmpty ? "" : "\(path(ctx.codingPath)): ") + ctx.debugDescription
        @unknown default: return error.localizedDescription
        }
    }
}

/// A keyboard shortcut like "cmd+shift+k" resolved to a virtual key code and modifiers.
public struct KeyCombo: Sendable, Equatable {
    public var keyCode: Int
    public var modifiers: Modifiers

    public init(keyCode: Int, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "fn": mods.insert(.function)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] else { return nil }
        return KeyCombo(keyCode: code, modifiers: mods)
    }

    /// US-layout virtual key codes.
    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()
}
