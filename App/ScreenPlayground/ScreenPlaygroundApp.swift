import AppKit
import Capture
import Export
import PlaygroundCore
import SwiftUI

@main
struct ScreenPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some SwiftUI.Scene {
        Settings {
            SettingsView().environment(AppModel.shared).preferredColorScheme(.light)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await UpdateChecker.shared.check(manual: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { AppModel.shared.recorder.showPicker() }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                Button("Open Project…") { AppModel.shared.openProjectPanel() }.keyboardShortcut("o")
                Button("Create Project from Video…") { AppModel.shared.importVideoPanel() }
                Button("Show Projects") { AppModel.shared.showHome() }.keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandMenu("Record") {
                Button("Record Display") { AppModel.shared.recorder.showPicker(mode: .display) }
                Button("Record Window") { AppModel.shared.recorder.showPicker(mode: .window) }
                Button("Record Area") { AppModel.shared.recorder.showPicker(mode: .area) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    /// True when the app is only hosting unit tests: skip all UI and system setup.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isHostingTests { return }
        MainActor.assumeIsolated {
            NSApp.appearance = NSAppearance(named: .aqua)
            statusItem = StatusItemController()
            HotKeys.shared.register()
            AppModel.shared.recoverUnfinishedRecordings()
            ControlServer.shared.start()
            UpdateChecker.shared.start()
            // Clipboard exports are only needed until they're pasted; drop ones older than a day.
            Task.detached(priority: .background) { ClipboardExport.cleanUp() }
            if !ProcessInfo.processInfo.arguments.contains("-PGNoHome") { AppModel.shared.showStartWindow() }
            ComponentGallery.showIfRequested()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { AppModel.shared.handle(url: $0) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.showStartWindow() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isHostingTests {
            ControlServer.shared.stop()
            MainActor.assumeIsolated { UpdateChecker.shared.installIfDeferred() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.recorder.isRecording else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "A recording is in progress"
            alert.informativeText = "Finish the recording before quitting, or quit and discard it."
            alert.addButton(withTitle: "Finish Recording")
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AppModel.shared.recorder.stop()
                return .terminateCancel
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        StatusItemController.makeMenu(includeQuit: false)
    }
}

/// Menu-bar icon: shows recording time while recording; click to stop.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Screen Playground")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let r = AppModel.shared.recorder
        if r.isRecording {
            let s = Int(r.elapsed)
            item.button?.image = NSImage(systemSymbolName: r.isPaused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: "Stop")
            item.button?.contentTintColor = .systemRed
            item.button?.title = String(format: " %d:%02d", s / 60, s % 60)
        } else {
            item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Screen Playground")
            item.button?.contentTintColor = nil
            item.button?.title = ""
        }
    }

    @objc private func clicked() {
        let r = AppModel.shared.recorder
        if r.isRecording {
            r.stop()
            return
        }
        item.menu = Self.makeMenu(includeQuit: true)
        item.button?.performClick(nil)
        item.menu = nil
    }

    static func makeMenu(includeQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("New Recording…", key: "\r", modifiers: [.command, .option]) { AppModel.shared.recorder.showPicker() })
        menu.addItem(ActionItem("Record Display") { AppModel.shared.recorder.showPicker(mode: .display) })
        menu.addItem(ActionItem("Record Window") { AppModel.shared.recorder.showPicker(mode: .window) })
        menu.addItem(ActionItem("Record Area") { AppModel.shared.recorder.showPicker(mode: .area) })
        menu.addItem(.separator())
        let recents = AppModel.shared.recents.prefix(6)
        if !recents.isEmpty {
            for url in recents {
                menu.addItem(ActionItem(url.deletingPathExtension().lastPathComponent) { AppModel.shared.openProject(url) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Show Projects") { AppModel.shared.showHome() })
        if let feed = UpdateChecker.shared.readyFeed {
            menu.addItem(ActionItem("Restart to Update to \(feed.version)") { UpdateChecker.shared.restartNow() })
        }
        menu.addItem(ActionItem("Open Clipboard Exports") { NSWorkspace.shared.open(ClipboardExport.folder) })
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Settings…", key: ",") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate() })
            menu.addItem(ActionItem("Quit Screen Playground", key: "q") { NSApp.terminate(nil) })
        }
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("rec.countdown") private var countdown = 3
    @AppStorage("rec.hideIcons") private var hideIcons = false

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Countdown", selection: $countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Hide desktop icons while recording", isOn: $hideIcons)
            }
            Section("Storage") {
                StorageRow()
            }
            Section("Shortcuts") {
                LabeledContent("Start / stop recording", value: "⌥⌘↩")
                LabeledContent("Pause / resume", value: "⌥⌘P")
                LabeledContent("Add recording flag", value: "⌃⌥⌘F")
                LabeledContent("Editor", value: "Space play · C split · X ripple delete · Z zoom · M mask · ⌘C copy frame")
            }
            Section("Agents & command line") {
                AgentSetupRow()
            }
            Section("Updates") {
                UpdatesRow()
            }
            Section("Permissions") {
                ForEach(Permission.allCases) { p in
                    LabeledContent(p.title) {
                        if PermissionCenter.isGranted(p) { Text("Allowed").foregroundStyle(.green) }
                        else { Button("Open System Settings") { NSWorkspace.shared.open(p.settingsURL) } }
                    }
                }
            }
            Section("About") {
                Text("Screen Playground is free for everyone. No accounts, no watermarks, no tracking.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 680)
    }
}

/// Connects agent apps by running the bundled `pgctl install` (one source of truth for the setup logic).
struct AgentSetupRow: View {
    @State private var message: String?
    @State private var failed = false

    struct Target: Identifiable {
        var id: String
        var title: String
        var detail: String
        var changes: String
    }

    static let targets = [
        Target(id: "claude-code", title: "Claude Code", detail: "Adds the demo-making skill; Claude Code runs pgctl from its terminal.",
               changes: "This adds a skill to ~/.claude/skills and links pgctl into ~/.local/bin."),
        Target(id: "claude-desktop", title: "Claude app", detail: "Adds Screen Playground as a tool in the Claude app's chats (MCP).",
               changes: "This adds a “screen-playground” entry to the Claude app's claude_desktop_config.json (a backup is kept)."),
        Target(id: "codex", title: "Codex", detail: "Adds Screen Playground as an MCP server for the Codex CLI and IDE extension.",
               changes: "This adds an [mcp_servers.screen-playground] entry to ~/.codex/config.toml (a backup is kept)."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Let AI agents record and edit demo videos for you. Agents click and type through a script while Screen Playground records; press Esc to stop them.")
                .foregroundStyle(.secondary)
            ForEach(Self.targets) { t in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 13, weight: .semibold))
                        Text(t.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up…") { confirm(t) }
                }
            }
            HStack {
                Button("Install Command-Line Tool Only") { run(["install", "--force"]) }
                Spacer()
            }
            if let message {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(failed ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func confirm(_ t: Target) {
        let alert = NSAlert()
        alert.messageText = "Set up \(t.title)?"
        alert.informativeText = t.changes
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(["install", "--force", "--for", t.id])
    }

    private func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pgctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            failed = process.terminationStatus != 0
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

/// Settings › Storage: where everything lives, and moving it somewhere else.
struct StorageRow: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?

    var body: some View {
        let storage = app.storage
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Location") {
                HStack {
                    Text(StorageLocation.displayPath(storage.root, home: StorageLocation.home))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.open(storage.root) }
                    Button("Change…") { change(from: storage) }
                }
            }
            if let service = StorageLocation.cloudService(for: storage.root) {
                Text("This folder syncs to \(service); recordings use \(service) storage.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func change(from old: StorageLocation) {
        guard !app.recorder.isRecording else { message = "Finish the recording first."; return }
        guard !app.hasOpenProjects else { message = "Close open projects first, then try again."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a new place for your recordings. A ScreenPlayground folder is created inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let new = StorageLocation(root: StorageLocation.root(inside: url), layout: .standard)
        guard new.root.standardizedFileURL != old.root.standardizedFileURL else { return }
        let count = app.recents.count
        let alert = NSAlert()
        alert.messageText = "Move your recordings to \(StorageLocation.displayPath(new.root, home: StorageLocation.home))?"
        alert.informativeText = count == 0 ? "New recordings will be saved there."
            : "Your \(count) project\(count == 1 ? "" : "s"), exports and presets will be moved there. Close any open projects first."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let moved = try StorageLocation.move(from: old, to: new)
            app.storageChanged()
            message = "Moved \(moved) project\(moved == 1 ? "" : "s")."
        } catch {
            app.storageChanged()
            AppModel.shared.presentError(error)
        }
    }
}

/// Settings › Updates.
struct UpdatesRow: View {
    @Bindable var updates = UpdateChecker.shared

    var body: some View {
        Toggle("Check for updates automatically", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
        LabeledContent("Version \(updates.currentVersion)") {
            HStack {
                switch updates.state {
                case .checking: ProgressView().controlSize(.small)
                case let .downloading(feed, p): Text("Downloading \(feed.version)… \(Int(p * 100))%").foregroundStyle(.secondary)
                case let .ready(feed, _): Button("Restart to Update to \(feed.version)") { updates.restartNow() }
                default:
                    if let last = updates.lastChecked {
                        Text("Checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    }
                }
                Button("Check Now") { Task { await updates.check(manual: true) } }
                    .disabled(updates.state == .checking)
            }
        }
        Text("Checks the Screen Playground website for a newer version. Nothing about you or your recordings is sent.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
