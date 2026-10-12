import Foundation
import PlaygroundCore

/// Built-in wallpapers. Procedural ones are generated on the GPU (no licensing concerns);
/// "system/<path>" wallpapers are read from the user's own macOS installation at runtime.
public struct WallpaperInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    /// Four corner colors for procedural wallpapers.
    public var palette: [RGBAColor]
    public var seed: Double
    /// Absolute file path for system wallpapers.
    public var filePath: String?
}

public enum WallpaperCatalog {
    static func p(_ id: String, _ name: String, _ cat: String, _ hex: [String], seed: Double) -> WallpaperInfo {
        WallpaperInfo(id: "procedural/\(id)", name: name, category: cat, palette: hex.map { RGBAColor(hex: $0) }, seed: seed)
    }

    public static let procedural: [WallpaperInfo] = [
        p("aurora", "Aurora", "Playground", ["#3F37C9", "#7B61FF", "#4CC9F0", "#B5179E"], seed: 1.3),
        p("sunset", "Sunset", "Playground", ["#FF7E5F", "#FEB47B", "#C850C0", "#FFCC70"], seed: 2.1),
        p("ocean", "Ocean", "Playground", ["#0F2027", "#2C5364", "#00B4DB", "#0083B0"], seed: 3.7),
        p("spring", "Spring", "Playground", ["#A8E063", "#56AB2F", "#F9F586", "#96E6A1"], seed: 4.2),
        p("candy", "Candy", "Playground", ["#FBC2EB", "#A6C1EE", "#FDCBF1", "#E6DEE9"], seed: 5.9),
        p("midnight", "Midnight", "Playground", ["#0B0C2A", "#232526", "#1A1A40", "#3A1C71"], seed: 6.4),
        p("ember", "Ember", "Playground", ["#F12711", "#F5AF19", "#8E0E00", "#E44D26"], seed: 7.7),
        p("mint", "Mint", "Playground", ["#43CEA2", "#185A9D", "#A8FFEB", "#3EADCF"], seed: 8.8),
        p("dusk", "Dusk", "Playground", ["#2C3E50", "#FD746C", "#4B6CB7", "#FF9068"], seed: 9.1),
        p("lavender", "Lavender", "Playground", ["#E0C3FC", "#8EC5FC", "#C2A9FF", "#F5F7FA"], seed: 10.5),
        p("forest", "Forest", "Playground", ["#134E5E", "#71B280", "#0B3D2E", "#A8C66C"], seed: 11.3),
        p("peach", "Peach", "Playground", ["#FFDDE1", "#EE9CA7", "#FFC3A0", "#FFAFBD"], seed: 12.2),
    ]

    /// macOS wallpapers installed on this Mac (read at runtime, never bundled).
    public static func systemWallpapers() -> [WallpaperInfo] {
        let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                WallpaperInfo(id: "system/\(url.lastPathComponent)", name: url.deletingPathExtension().lastPathComponent,
                              category: "macOS", palette: [], seed: 0, filePath: url.path)
            }
    }

    public static func info(for id: String) -> WallpaperInfo? {
        if let p = procedural.first(where: { $0.id == id }) { return p }
        if id.hasPrefix("system/") {
            let name = String(id.dropFirst("system/".count))
            let path = "/System/Library/Desktop Pictures/\(name)"
            return WallpaperInfo(id: id, name: name, category: "macOS", palette: [], seed: 0, filePath: path)
        }
        return nil
    }
}
