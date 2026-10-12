import PlaygroundCore

/// Generates zoom ranges from click positions.
///
/// Clicks are grouped greedily: a click joins the current group when it is close in time
/// (≤ `maxClickGap`) and the group's bounding box still fits in a viewport at the zoom level.
/// Each group's range starts `leadIn` before the first click so the camera has settled when the
/// click happens, and ends `leadOut` after the last.
public enum AutoZoom {
    public struct Click: Sendable {
        public var t: Double
        public var point: NormPoint
        public init(t: Double, point: NormPoint) {
            self.t = t
            self.point = point
        }
    }

    public static func generate(clicks: [Click], duration: Double, config: AutoZoomConfig) -> [ZoomRange] {
        guard config.enabled, duration > 0 else { return [] }
        let sorted = clicks
            .filter { $0.point.x >= 0 && $0.point.x <= 1 && $0.point.y >= 0 && $0.point.y <= 1 }
            .sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }

        let viewport = 1 / config.defaultLevel
        // Margin so clicks are never right at the viewport edge.
        let fit = viewport * 0.8

        struct Group { var first: Double; var last: Double; var box: NormRect }
        var groups: [Group] = []
        for c in sorted {
            if var g = groups.last, c.t - g.last <= config.maxClickGap {
                let box = g.box.union(c.point)
                if box.width <= fit && box.height <= fit {
                    g.last = c.t
                    g.box = box
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append(Group(first: c.t, last: c.t, box: NormRect(x: c.point.x, y: c.point.y, width: 0, height: 0)))
        }

        // Build ranges and merge ones that nearly touch.
        var ranges: [(start: Double, end: Double, box: NormRect)] = []
        for g in groups {
            let start = max(0, g.first - config.leadIn)
            let end = min(duration, g.last + config.leadOut)
            if var prev = ranges.last, start - prev.end < config.mergeGap {
                var merged = prev.box
                merged = merged.union(NormPoint(g.box.minX, g.box.minY)).union(NormPoint(g.box.maxX, g.box.maxY))
                if merged.width <= fit && merged.height <= fit {
                    prev.end = end
                    prev.box = merged
                    ranges[ranges.count - 1] = prev
                    continue
                }
                // Too far apart to share a viewport: butt them up without overlapping.
                let mid = (prev.end + start) / 2
                if start < prev.end {
                    ranges[ranges.count - 1].end = mid
                    ranges.append((mid, end, g.box))
                    continue
                }
            }
            ranges.append((start, end, g.box))
        }

        return ranges.compactMap { r in
            guard r.end - r.start >= Edits.minimumZoomDuration else { return nil }
            let extent = max(r.box.width, r.box.height)
            let fitLevel = extent > 0 ? 0.8 / extent : config.defaultLevel
            let level = min(max(min(config.defaultLevel, fitLevel), 1.3), config.maxLevel)
            return ZoomRange(source: SourceRange(r.start, r.end), level: (level * 100).rounded() / 100,
                             mode: .auto, isAuto: true)
        }
    }

    /// Replaces auto-generated zooms, keeping the user's own.
    public static func regenerate(_ scene: Scene, clicks: [Click], duration: Double, config: AutoZoomConfig) -> Scene {
        var out = scene
        let manual = scene.zooms.filter { !$0.isAuto }
        let auto = generate(clicks: clicks, duration: duration, config: config).filter { z in
            !manual.contains { $0.source.overlaps(z.source) }
        }
        out.zooms = (manual + auto).sorted { $0.source.start < $1.source.start }
        return out
    }
}
