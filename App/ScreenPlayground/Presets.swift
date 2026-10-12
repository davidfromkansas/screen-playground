import AppKit
import Foundation
import PlaygroundCore
import SwiftUI

/// A saved look (background, frame, cursor, camera, animation...) as a `.spgpreset` JSON file.
struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var config: ProjectConfig
}

@MainActor
enum PresetStore {
    /// Tests point this at a temporary folder.
    static var folderOverride: URL?

    static var folder: URL {
        let dir = folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Playground/Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func all() -> [Preset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "spgpreset" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let fallback = Preset(name: url.deletingPathExtension().lastPathComponent, config: ProjectConfig())
            return try? TolerantJSON.decode(Preset.self, from: data, defaults: fallback)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ preset: Preset) {
        let url = folder.appendingPathComponent("\(preset.name).spgpreset")
        try? TolerantJSON.encode(preset).write(to: url, options: .atomic)
    }

    static func delete(_ preset: Preset) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(preset.name).spgpreset"))
        if defaultPresetName == preset.name { defaultPresetName = nil }
    }

    static var defaultPresetName: String? {
        get { UserDefaults.standard.string(forKey: "preset.default") }
        set { UserDefaults.standard.set(newValue, forKey: "preset.default") }
    }

    /// Settings applied to new recordings: the default preset, else the last edited project's look.
    static var configForNewRecordings: ProjectConfig? {
        if let name = defaultPresetName, let p = all().first(where: { $0.name == name }) { return p.config }
        if let data = UserDefaults.standard.data(forKey: "preset.lastConfig") {
            return try? TolerantJSON.decode(ProjectConfig.self, from: data, defaults: ProjectConfig())
        }
        return nil
    }

    static func rememberLast(_ config: ProjectConfig) {
        if let data = try? TolerantJSON.encode(config) { UserDefaults.standard.set(data, forKey: "preset.lastConfig") }
    }

    static func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "spgpreset") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
    }
}

struct PresetsMenu: View {
    var model: EditorModel
    @State private var naming = false
    @State private var newName = ""
    @State private var presets: [Preset] = []

    var body: some View {
        Menu {
            Button("Save current look as preset…") { newName = ""; naming = true }
            if !presets.isEmpty {
                Divider()
                ForEach(presets) { p in
                    Menu(p.name + (PresetStore.defaultPresetName == p.name ? "  (default)" : "")) {
                        Button("Apply") { model.update("Apply preset") { $0.config = p.config } }
                        Button("Use for new recordings") { PresetStore.defaultPresetName = p.name; reload() }
                        Button("Delete", role: .destructive) { PresetStore.delete(p); reload() }
                    }
                }
            }
            Divider()
            Button("Import preset…") { PresetStore.importPanel(); reload() }
            Button("Show presets folder") { NSWorkspace.shared.open(PresetStore.folder) }
        } label: { Label("Presets", systemImage: "sparkles") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear(perform: reload)
            .alert("Save preset", isPresented: $naming) {
                TextField("Preset name", text: $newName)
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    PresetStore.save(Preset(name: name, config: model.doc.config))
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    func reload() { presets = PresetStore.all() }
}
