import AppKit
import ApplicationServices
import Capture
import Composition
import Export
import Foundation
import Media
import PlaygroundCore
import Timeline

/// Performs a `DemoScript` while recording its window, then finalizes and (optionally) exports it.
///
/// The cursor and keyboard are driven with real events, so the recording's input log is as clean as a
/// careful human's: auto-zoom, click effects and cursor smoothing work exactly as for a person.
/// Pressing Esc or moving the mouse stops the run (the partial recording is kept).
@MainActor
final class DemoRunner {
    struct StepResult {
        var index: Int
        var action: String
        var t: Double
    }

    private let script: DemoScript
    private let synth = InputSynth()
    private var monitors: [Any] = []
    private var abortReason: String?
    private var pid: pid_t = 0
    private var window: AXUIElement?
    private var windowID: CGWindowID?
    private var results: [StepResult] = []
    private var warnings: [String] = []

    var recorder: RecorderController { AppModel.shared.recorder }

    init(script: DemoScript) { self.script = script }

    // MARK: Run

    func run(outputOverride: String? = nil, openEditor: Bool? = nil, folder: URL? = nil) async throws -> JSONValue {
        try preflight()
        try await prepareTarget()
        let options = script.options
        guard let window, let windowID = captureWindowID() else {
            throw ControlError("target-not-found", "Couldn't find the \(script.target.app) window to record.")
        }
        self.windowID = windowID

        var rec = RecorderController.AutomationOptions()
        rec.countdown = 0
        rec.maxDuration = options?.maxDuration ?? 180
        rec.name = recordingName()
        rec.folder = folder
        let cutIdle = options?.cutIdle ?? 1.5
        rec.cutIdle = cutIdle > 0 ? cutIdle : nil
        if options?.microphone == true { rec.microphoneID = CaptureCatalog.microphones().first?.id }
        let project = try await recorder.startAutomated(target: .window(windowID), options: rec)

        startAbortMonitor()
        defer { stopAbortMonitor() }

        var failure: Error?
        do {
            try await pause(0.6)
            for (i, step) in script.steps.enumerated() {
                try await perform(step, index: i, in: window)
            }
            try await pause(0.8)
        } catch {
            failure = error
        }

        // Always finish the recording so nothing is lost; an aborted run keeps what was recorded.
        stopAbortMonitor()
        let bundle: ProjectBundle
        do {
            bundle = try await recorder.finish(openEditor: false)
        } catch {
            throw failure ?? error
        }
        if let failure {
            let base = failure as? ControlError ?? ControlError("failed", failure.localizedDescription)
            let stepNote = results.count < script.steps.count ? " at step \(results.count + 1) of \(script.steps.count)" : ""
            throw ControlError(base.code, base.message + stepNote + ". The partial recording was saved: \(bundle.url.path)", fix: base.fix)
        }

        try applyStyle(to: bundle)
        var outputPath: String?
        let outSpec = script.output
        if let file = outputOverride ?? outSpec?.file {
            outputPath = try await export(bundle, to: file, spec: outSpec)
        }
        if openEditor ?? outSpec?.openEditor ?? false { AppModel.shared.openProject(bundle.url) }

        let doc = try bundle.loadDocument()
        let duration = TimeMap(slices: doc.scene.slices).duration
        return [
            "project": .string(project.path),
            "output": outputPath.map { .string($0) } ?? .null,
            "duration": .number((duration * 100).rounded() / 100),
            "zooms": .number(Double(doc.scene.zooms.count)),
            "captions": .number(Double(doc.scene.captions.count)),
            "steps": .array(results.map { ["index": .number(Double($0.index + 1)), "action": .string($0.action),
                                           "t": .number(($0.t * 100).rounded() / 100)] }),
            "warnings": .array(warnings.map { .string($0) }),
        ]
    }

    // MARK: Preparation

    private func preflight() throws {
        guard PermissionCenter.isGranted(.screenRecording) else {
            throw ControlError("permission", "Screen Recording permission is not granted.",
                               fix: "Open Screen Playground and allow Screen Recording in System Settings › Privacy & Security.")
        }
        guard AXIsProcessTrusted() else {
            throw ControlError("permission", "Accessibility permission is needed to click and type for the demo.",
                               fix: "Allow Screen Playground in System Settings › Privacy & Security › Accessibility, then retry.")
        }
        guard recorder.state == .idle else {
            throw ControlError("busy", "A recording is already in progress.", fix: "Run `pgctl record stop` or `pgctl record cancel` first.")
        }
    }

    private func prepareTarget() async throws {
        let target = script.target
        let appURL = try Self.applicationURL(target.app)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let urlString = target.url {
            guard let url = URL(string: urlString), url.scheme != nil else {
                throw ControlError("bad-script", "target.url \"\(urlString)\" isn't a full URL (include http:// or file://).")
            }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: appURL)?.bundleIdentifier ?? "").first else {
            throw ControlError("target-not-found", "\(target.app) didn't start.")
        }
        pid = app.processIdentifier
        AXLocator.enableWebAccessibility(pid: pid)

        // Wait for a window (with the right title, if asked).
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let candidates = AXLocator.windows(pid: pid)
            if let w = candidates.first(where: { target.title == nil || AXLocator.title($0).localizedCaseInsensitiveContains(target.title!) }) {
                window = w
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let window else {
            throw ControlError("target-not-found", "No \(target.app) window\(target.title.map { " titled \"\($0)\"" } ?? "") appeared.")
        }

        if let size = target.windowSize, let screen = NSScreen.main {
            // Centre on the main display (global top-left coordinates).
            let visible = screen.visibleFrame
            let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let w = min(size[0], visible.width), h = min(size[1], visible.height)
            let origin = CGPoint(x: visible.midX - w / 2, y: mainHeight - visible.midY - h / 2)
            AXLocator.setFrame(window, origin: origin, size: CGSize(width: w, height: h))
            if let f = AXLocator.frame(window), abs(f.width - w) > 2 || abs(f.height - h) > 2 {
                warnings.append("The window is \(Int(f.width))×\(Int(f.height)) instead of \(Int(w))×\(Int(h)).")
            }
        }
        app.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let preRoll = script.options?.preRoll ?? (target.url != nil ? 1.5 : 0.5)
        try await Task.sleep(nanoseconds: UInt64(preRoll * 1e9))
    }

    /// The CGWindowID of the AX window (same app, nearly the same frame).
    private func captureWindowID() -> CGWindowID? {
        guard let window, let frame = AXLocator.frame(window) else { return nil }
        let mine = CaptureCatalog.windows().filter { $0.pid == pid }
        return mine.min { a, b in
            abs(a.frame.minX - frame.minX) + abs(a.frame.minY - frame.minY) + abs(a.frame.width - frame.width)
                < abs(b.frame.minX - frame.minX) + abs(b.frame.minY - frame.minY) + abs(b.frame.width - frame.width)
        }?.id
    }

    static func applicationURL(_ app: String) throws -> URL {
        let ws = NSWorkspace.shared
        if app.contains("."), let url = ws.urlForApplication(withBundleIdentifier: app) { return url }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame }),
           let url = running.bundleURL { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", "\(home)/Applications"] {
            let url = URL(fileURLWithPath: "\(folder)/\(app).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw ControlError("app-not-found", "Couldn't find an app called \"\(app)\".", fix: "Use its exact name (\"Google Chrome\") or bundle ID (\"com.google.Chrome\").")
    }

    private func recordingName() -> String {
        if let file = script.output?.file { return URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Demo \(script.target.app) \(f.string(from: Date()))"
    }

    // MARK: Steps

    private func perform(_ step: DemoScript.Step, index: Int, in window: AXUIElement) async throws {
        try checkAbort()
        let t = recorder.elapsed
        if let caption = step.caption, !caption.isEmpty { try recorder.addMark(.caption, text: caption) }

        switch step.action {
        case let .click(locator), let .doubleClick(locator), let .rightClick(locator):
            let (point, element) = try AXLocator.locate(locator, in: window)
            try await ensureReachable(point, target: element, locator.summary)
            if let zoom = step.zoom { try recorder.addMark(.zoom, value: zoom) }
            let count = if case .doubleClick = step.action { 2 } else { 1 }
            let button: CGMouseButton = if case .rightClick = step.action { .right } else { .left }
            try await synth.click(at: point, button: button, count: count)

        case let .hover(locator):
            let (point, _) = try AXLocator.locate(locator, in: window)
            try await synth.move(to: point)

        case let .type(action):
            if let into = action.into {
                let (point, element) = try AXLocator.locate(into, in: window, wantInput: true)
                if element?.isSecure == true { throw secureFieldError() }
                try await ensureReachable(point, target: element, into.summary)
                if let zoom = step.zoom { try recorder.addMark(.zoom, value: zoom) }
                try await synth.click(at: point)
                try await pause(0.15)
            }
            if let focused = AXLocator.focusedElement(pid: pid), AXLocator.describe(focused)?.isSecure == true {
                throw secureFieldError()
            }
            if action.replace == true { try await synth.press(KeyCombo(keyCode: 0, modifiers: .command)) }
            if let speed = action.speed, speed > 1 { try recorder.addMark(.speedStart, value: speed) }
            try await synth.type(action.text, cps: script.options?.typingSpeed ?? 14)
            if let speed = action.speed, speed > 1 { try recorder.addMark(.speedEnd) }
            if action.submit == true {
                try await pause(0.2)
                try await synth.press(KeyCombo(keyCode: 36, modifiers: []))
            }

        case let .key(combo):
            guard let parsed = KeyCombo.parse(combo) else { throw ControlError("bad-script", "Unknown key \"\(combo)\".") }
            try await synth.press(parsed)

        case let .scroll(action):
            let point: CGPoint
            if let at = action.at {
                point = try AXLocator.locate(at, in: window).point
            } else {
                let f = AXLocator.frame(window) ?? .zero
                point = CGPoint(x: f.midX, y: f.midY)
            }
            try await synth.scroll(direction: action.direction, lines: action.amount ?? 5, at: point)

        case let .wait(seconds):
            try recorder.addMark(.hold, value: seconds)
            try await pause(seconds)
        }

        if let hold = step.hold, hold > 0 {
            try recorder.addMark(.hold, value: hold)
            try await pause(hold)
        }
        results.append(StepResult(index: index, action: step.action.name, t: t))
        try await pause(script.options?.settle ?? 0.5)
    }

    /// Makes sure a click at `point` reaches the target before clicking:
    /// - inside the target app, the element there must be the target or inside it (catches autofill and
    ///   password-manager menus, which can live in the browser's own process);
    /// - no normal window of another app may sit above the target window at that point.
    /// Covered targets get one Esc; if still covered we stop rather than click the wrong thing.
    private func ensureReachable(_ point: CGPoint, target: AXLocator.Element?, _ what: String) async throws {
        for attempt in 0..<3 {
            var cover: String?
            if let target {
                var hit: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit)
                if let hit, !Self.isInside(hit, target.ref) {
                    cover = AXLocator.describe(hit)?.summary ?? "a popup"
                } else if hit == nil {
                    cover = "something (the click point couldn't be checked)"
                }
            }
            if cover == nil, let other = windowAbove(point) { cover = "a window from \(other)" }
            guard let cover else { return }
            if attempt == 0 { try await synth.press(KeyCombo(keyCode: 53, modifiers: [])) } // Esc closes most popups
            try await pause(0.35)
            if attempt == 2 {
                throw ControlError("target-covered", "\(cover) is covering \(what), so nothing was clicked",
                                   fix: "Close that popup or window (for example a password manager's autofill menu), then run again.")
            }
        }
    }

    /// The app owning a normal (layer 0) window above the target window at `point`, if any.
    private func windowAbove(_ point: CGPoint) -> String? {
        guard let windowID, let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b),
                  rect.contains(point) else { continue }
            return w[kCGWindowOwnerName as String] as? String ?? "another app"
        }
        return nil
    }

    /// True when `hit` is `target` or one of its descendants.
    static func isInside(_ hit: AXUIElement, _ target: AXUIElement) -> Bool {
        var current: AXUIElement? = hit
        for _ in 0..<40 {
            guard let el = current else { return false }
            if CFEqual(el, target) { return true }
            current = AXLocator.attr(el, kAXParentAttribute)
        }
        return false
    }

    private func secureFieldError() -> ControlError {
        ControlError("secure-field", "Refused to type into a password field",
                     fix: "Demos never type passwords. If the app needs a login, sign in to it before running the demo and remove this step.")
    }

    private func pause(_ seconds: Double) async throws {
        try checkAbort()
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1e9))
        try checkAbort()
    }

    // MARK: Abort (Esc or a person moving the mouse)

    private func checkAbort() throws {
        if let abortReason { throw ControlError("aborted", abortReason) }
        if recorder.state != .recording { throw ControlError("aborted", "The recording was stopped.") }
    }

    private func startAbortMonitor() {
        synth.checkAbort = { [weak self] in try self?.checkAbort() }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != InputSynth.marker else { return }
            if event.type == .keyDown, event.keyCode == 53 {
                self.abortReason = "Stopped: Esc was pressed."
            } else if event.type == .mouseMoved || event.type == .leftMouseDown {
                let here = NSEvent.mouseLocation
                let mainHeight = NSScreen.screens.first?.frame.height ?? 0
                let p = CGPoint(x: here.x, y: mainHeight - here.y)
                if let last = self.synth.lastPosted, hypot(p.x - last.x, p.y - last.y) > 40 {
                    self.abortReason = "Stopped: the mouse was moved by hand."
                }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown], handler: { handler($0); return $0 }) {
            monitors.append(l)
        }
    }

    private func stopAbortMonitor() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Finishing

    private func applyStyle(to bundle: ProjectBundle) throws {
        guard let style = script.style else { return }
        var doc = try bundle.loadDocument()
        if let name = style.preset {
            guard let preset = PresetStore.all().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                warnings.append("No preset named \"\(name)\"; kept the default look.")
                return
            }
            doc.config = preset.config
        }
        if let a = style.aspect, let aspect = AspectRatio(rawValue: a) { doc.config.output.aspect = aspect }
        try bundle.saveDocument(doc)
    }

    private func export(_ bundle: ProjectBundle, to file: String, spec: DemoScript.OutputSpec?) async throws -> String {
        let out = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = ExportSettings()
        switch out.pathExtension.lowercased() {
        case "gif": settings = .gifDefault
        case "mov": settings.format = .prores
        default: settings.format = .mp4
        }
        if let r = spec?.res, let preset = ResolutionPreset(rawValue: r) { settings.resolution = preset }
        if let f = spec?.fps { settings.fps = f }
        if let q = spec?.quality.flatMap(ExportQuality.init) { settings.quality = q }
        let project = try await LoadedProject.load(bundle)
        try? FileManager.default.removeItem(at: out)
        try await Exporter(project: project, document: project.document, settings: settings).run(to: out) { _ in }
        return out.path
    }
}
