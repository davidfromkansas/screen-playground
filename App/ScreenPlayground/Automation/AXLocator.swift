import AppKit
import ApplicationServices
import PlaygroundCore

/// Finds on-screen elements of another app through the Accessibility API (web content included).
@MainActor
enum AXLocator {
    struct Element {
        let ref: AXUIElement
        let role: String
        let subrole: String
        /// Visible text: title, value, description.
        let texts: [String]
        /// Field labels: placeholder, description, title, linked title element.
        let labels: [String]
        /// Global frame in points, top-left origin (same space as CGEvent locations).
        let frame: CGRect

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var isTextInput: Bool { ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"].contains(role) }
        var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
        var summary: String { (texts.first ?? labels.first ?? "") + " (\(role.replacingOccurrences(of: "AX", with: "")))" }
    }

    // MARK: Attributes

    static func attr<T>(_ el: AXUIElement, _ name: String, as: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attr(el, kAXPositionAttribute), let sizeValue: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ el: AXUIElement, origin: CGPoint?, size: CGSize?) {
        if var size, let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
        if var origin, let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }

    /// Chromium and Electron apps only build their web accessibility tree when asked.
    static func enableWebAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The app's windows, focused/main first.
    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var list: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        if let focused: AXUIElement = attr(app, kAXFocusedWindowAttribute) {
            list.removeAll { CFEqual($0, focused) }
            list.insert(focused, at: 0)
        }
        return list.filter { (frame($0)?.width ?? 0) > 100 }
    }

    static func title(_ el: AXUIElement) -> String { attr(el, kAXTitleAttribute) ?? "" }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        attr(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    static func describe(_ el: AXUIElement) -> Element? {
        guard let f = frame(el), f.width >= 2, f.height >= 2 else { return nil }
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let subrole: String = attr(el, kAXSubroleAttribute) ?? ""
        var texts: [String] = []
        if let t: String = attr(el, kAXTitleAttribute), !t.isEmpty { texts.append(t) }
        if let v: String = attr(el, kAXValueAttribute), !v.isEmpty, v.count <= 200, !["AXTextField", "AXTextArea", "AXSecureTextField"].contains(role) {
            texts.append(v)
        }
        if let d: String = attr(el, kAXDescriptionAttribute), !d.isEmpty { texts.append(d) }
        var labels: [String] = []
        if let p: String = attr(el, kAXPlaceholderValueAttribute), !p.isEmpty { labels.append(p) }
        if let d: String = attr(el, kAXDescriptionAttribute), !d.isEmpty { labels.append(d) }
        if let t: String = attr(el, kAXTitleAttribute), !t.isEmpty { labels.append(t) }
        if let titleEl: AXUIElement = attr(el, kAXTitleUIElementAttribute) {
            if let v: String = attr(titleEl, kAXValueAttribute), !v.isEmpty { labels.append(v) }
            if let t: String = attr(titleEl, kAXTitleAttribute), !t.isEmpty { labels.append(t) }
        }
        return Element(ref: el, role: role, subrole: subrole, texts: texts, labels: labels, frame: f)
    }

    /// Visible elements in a window, breadth first (bounded so huge pages stay fast).
    static func elements(in window: AXUIElement, limit: Int = 8000) -> [Element] {
        guard let windowFrame = frame(window) else { return [] }
        var out: [Element] = []
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let el = queue.removeFirst()
            visited += 1
            if let e = describe(el), e.frame.intersects(windowFrame) { out.append(e) }
            if let children: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        return out
    }

    // MARK: Matching

    static let roleAliases: [String: Set<String>] = [
        "button": ["AXButton", "AXPopUpButton", "AXMenuButton"],
        "link": ["AXLink"],
        "textfield": ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"],
        "field": ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"],
        "checkbox": ["AXCheckBox"],
        "radio": ["AXRadioButton"],
        "tab": ["AXRadioButton", "AXTab"],
        "menuitem": ["AXMenuItem"],
        "image": ["AXImage"],
        "heading": ["AXHeading"],
        "text": ["AXStaticText"],
        "row": ["AXRow", "AXCell"],
    ]

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 3 exact, 2 prefix, 1 contains, 0 no match.
    static func score(_ candidates: [String], _ wanted: String) -> Int {
        let w = normalize(wanted)
        guard !w.isEmpty else { return 0 }
        return candidates.map { c -> Int in
            let n = normalize(c)
            if n == w { return 3 }
            if n.hasPrefix(w) { return 2 }
            if n.contains(w) { return 1 }
            return 0
        }.max() ?? 0
    }

    static func roleMatches(_ e: Element, _ role: String?) -> Bool {
        guard let role else { return true }
        if role.hasPrefix("AX") { return e.role == role || e.subrole == role }
        return roleAliases[role.lowercased()]?.contains(e.role) ?? (e.role.lowercased() == "ax\(role.lowercased())")
    }

    /// Resolves a script locator in a window. Throws `target-not-found` with nearby suggestions.
    static func locate(_ locator: DemoScript.Locator, in window: AXUIElement, wantInput: Bool = false) throws -> (point: CGPoint, element: Element?) {
        guard let windowFrame = frame(window) else { throw ControlError("window-gone", "The target window closed.") }
        if let p = locator.point {
            let point = CGPoint(x: windowFrame.minX + p[0], y: windowFrame.minY + p[1])
            guard windowFrame.contains(point) else {
                throw ControlError("target-not-found", "point \(p) is outside the \(Int(windowFrame.width))×\(Int(windowFrame.height)) window.")
            }
            return (point, nil)
        }
        let all = elements(in: window)
        var scored: [(Int, Element)] = []
        for e in all where roleMatches(e, locator.role) {
            var s = 0
            if let text = locator.text { s = score(e.texts, text) }
            if let label = locator.label {
                guard e.isTextInput || !wantInput else { continue }
                s = max(s, score(e.labels, label) + (e.isTextInput ? 1 : 0))
            }
            if s > 0 { scored.append((s, e)) }
        }
        // A label written next to a field (not linked to it): use the nearest input below or to the right.
        if scored.isEmpty, let label = locator.label {
            let labelTexts = all.filter { $0.role == "AXStaticText" && score($0.texts, label) >= 2 }
            let inputs = all.filter(\.isTextInput)
            if let l = labelTexts.first, let nearest = inputs.min(by: { distance(l.frame, $0.frame) < distance(l.frame, $1.frame) }),
               distance(l.frame, nearest.frame) < 200 {
                scored = [(1, nearest)]
            }
        }
        guard let best = scored.map(\.0).max() else {
            throw notFound(locator, among: all)
        }
        // Prefer actionable roles within the best score, then top-to-bottom, left-to-right.
        let actionable: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton",
                                       "AXPopUpButton", "AXMenuItem", "AXComboBox", "AXMenuButton", "AXTab"]
        var top = scored.filter { $0.0 == best }.map(\.1)
        if top.contains(where: { actionable.contains($0.role) }) { top = top.filter { actionable.contains($0.role) } }
        top = dedupeNested(top).sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let i = (locator.index ?? 1) - 1
        guard top.indices.contains(i) else {
            throw ControlError("target-not-found", "Only \(top.count) match\(top.count == 1 ? "" : "es") for \(locator.summary); index \(i + 1) is out of range.")
        }
        let el = top[i]
        return (CGPoint(x: el.frame.midX, y: el.frame.midY), el)
    }

    /// Drops elements that sit inside another match (a link and its own text).
    static func dedupeNested(_ list: [Element]) -> [Element] {
        list.filter { e in !list.contains { other in other.frame != e.frame && other.frame.contains(e.frame) && other.texts == e.texts } }
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX)), dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    static func notFound(_ locator: DemoScript.Locator, among all: [Element]) -> ControlError {
        let visible = all.filter { !$0.texts.isEmpty || ($0.isTextInput && !$0.labels.isEmpty) }
            .filter { ["AXButton", "AXLink", "AXTextField", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                       "AXMenuItem", "AXHeading", "AXTextArea", "AXComboBox", "AXTab"].contains($0.role) }
        var seen = Set<String>()
        let names = visible.map(\.summary).filter { seen.insert($0).inserted }.prefix(25)
        return ControlError("target-not-found", "Couldn't find \(locator.summary) in the window.",
                            fix: names.isEmpty ? "The window has no readable elements yet — add a wait, or use a point."
                                               : "Visible targets: " + names.joined(separator: " · "))
    }
}
