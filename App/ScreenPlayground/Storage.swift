import AppKit
import Foundation
import PlaygroundCore

/// Where Screen Playground keeps everything. One folder holds Projects, Exports and Presets.
///
/// - New users choose it on the welcome screen (default `~/ScreenPlayground`).
/// - People who already have `~/ScreenPlayground` (or saved a choice) aren't asked again.
/// - People from 0.2 and earlier keep their existing `~/Movies/Screen Playground` layout, untouched.
struct StorageLocation: Equatable {
    enum Layout: String { case standard, legacy }

    var root: URL
    var layout: Layout

    var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    var exports: URL { layout == .legacy ? root : root.appendingPathComponent("Exports", isDirectory: true) }
    var presets: URL {
        layout == .legacy
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Screen Playground/Presets", isDirectory: true)
            : root.appendingPathComponent("Presets", isDirectory: true)
    }

    static func == (a: StorageLocation, b: StorageLocation) -> Bool {
        a.root.standardizedFileURL.path == b.root.standardizedFileURL.path && a.layout == b.layout
    }

    static let defaultsKey = "storage.root"
    static let layoutKey = "storage.layout"

    static func defaultRoot(home: URL) -> URL { home.appendingPathComponent("ScreenPlayground", isDirectory: true) }
    static func legacyRoot(home: URL) -> URL { home.appendingPathComponent("Movies/Screen Playground", isDirectory: true) }

    enum Resolution: Equatable {
        case ready(StorageLocation)
        /// First launch: show the welcome screen.
        case needsChoice
    }

    /// Decides the storage location without side effects (unit-tested).
    static func resolve(saved: String?, savedLayout: String?, home: URL, exists: (URL) -> Bool) -> Resolution {
        if let saved, !saved.isEmpty {
            return .ready(StorageLocation(root: URL(fileURLWithPath: saved, isDirectory: true),
                                          layout: Layout(rawValue: savedLayout ?? "") ?? .standard))
        }
        if exists(defaultRoot(home: home)) { return .ready(StorageLocation(root: defaultRoot(home: home), layout: .standard)) }
        if exists(legacyRoot(home: home).appendingPathComponent("Projects")) {
            return .ready(StorageLocation(root: legacyRoot(home: home), layout: .legacy))
        }
        return .needsChoice
    }

    // MARK: Current

    @MainActor static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    @MainActor static var resolution: Resolution {
        if ProcessInfo.processInfo.arguments.contains("-PGOnboarding") { return .needsChoice } // QA: preview the welcome screen
        let d = UserDefaults.standard
        return resolve(saved: d.string(forKey: defaultsKey), savedLayout: d.string(forKey: layoutKey), home: home) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// The location in use. Before a choice is made (e.g. an agent launched the app headless), the default.
    @MainActor static var current: StorageLocation {
        if case let .ready(location) = resolution { return location }
        return StorageLocation(root: defaultRoot(home: home), layout: .standard)
    }

    /// Saves the choice and creates the folders.
    @MainActor static func choose(_ location: StorageLocation) throws {
        for folder in [location.projects, location.exports, location.presets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        UserDefaults.standard.set(location.root.path, forKey: defaultsKey)
        UserDefaults.standard.set(location.layout.rawValue, forKey: layoutKey)
    }

    /// The root to use inside a folder the person picked: the folder itself if it's already called
    /// ScreenPlayground, otherwise a ScreenPlayground folder inside it.
    static func root(inside picked: URL) -> URL {
        picked.lastPathComponent == "ScreenPlayground" ? picked : picked.appendingPathComponent("ScreenPlayground", isDirectory: true)
    }

    // MARK: Details for the UI

    /// "iCloud Drive", "Dropbox", … when the folder syncs to the cloud.
    static func cloudService(for url: URL) -> String? {
        let path = url.path
        if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }
        if let values = try? url.deletingLastPathComponent().resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return "iCloud Drive"
        }
        if let range = path.range(of: "/Library/CloudStorage/") {
            let provider = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? "a cloud service"
            return provider.split(separator: "-").first.map(String.init) ?? provider
        }
        for name in ["Dropbox", "Google Drive", "OneDrive", "Box"] where path.contains("/\(name)/") { return name }
        return nil
    }

    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func displayPath(_ url: URL, home: URL) -> String {
        url.path.hasPrefix(home.path) ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    // MARK: Moving

    /// Moves projects (and exports/presets for the standard layout) into a new location.
    @MainActor static func move(from old: StorageLocation, to new: StorageLocation) throws -> Int {
        let fm = FileManager.default
        try choose(new)
        var moved = 0
        let pairs: [(URL, URL, (URL) -> Bool)] = [
            (old.projects, new.projects, { $0.pathExtension == ProjectBundle.fileExtension }),
            (old.presets, new.presets, { $0.pathExtension == "spgpreset" }),
            (old.exports, new.exports, { ["mp4", "gif", "mov"].contains($0.pathExtension.lowercased()) }),
        ]
        for (from, to, include) in pairs where from.standardizedFileURL != to.standardizedFileURL {
            let items = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
            for item in items where include(item) {
                let dest = to.appendingPathComponent(item.lastPathComponent)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try fm.moveItem(at: item, to: dest)
                if item.pathExtension == ProjectBundle.fileExtension { moved += 1 }
            }
        }
        return moved
    }
}
