import PlaygroundCore

/// Finds stretches where nothing happens (no mouse, clicks or keys) so they can be cut.
public enum IdleDetector {
    /// Source ranges with no input for longer than `minGap`, shrunk by `padding` at each end so cuts
    /// never land right on an action. `keep` ranges (deliberate holds) are never cut.
    public static func idleRanges(events: RecordingEvents, duration: Double, minGap: Double = 1.5, padding: Double = 0.4,
                                  keep: [SourceRange] = []) -> [SourceRange] {
        var times = events.moves.map(\.t) + events.clicks.map(\.t) + events.keys.map(\.t)
        times = times.filter { $0 >= 0 && $0 <= duration }.sorted()
        // Treat the start and end as activity so the video keeps a short lead-in and tail.
        let points = [0.0] + times + [duration]
        var gaps: [SourceRange] = []
        for (a, b) in zip(points, points.dropFirst()) where b - a > minGap {
            let start = a + padding, end = b - padding
            if end - start > 0.1 { gaps.append(SourceRange(start, end)) }
        }
        // Remove the kept ranges from each gap.
        return gaps.flatMap { gap in subtract(keep, from: gap) }.filter { $0.duration > 0.1 }
    }

    static func subtract(_ holes: [SourceRange], from range: SourceRange) -> [SourceRange] {
        var pieces = [range]
        for hole in holes {
            pieces = pieces.flatMap { p -> [SourceRange] in
                guard p.overlaps(hole) else { return [p] }
                var out: [SourceRange] = []
                if hole.start > p.start { out.append(SourceRange(p.start, hole.start)) }
                if hole.end < p.end { out.append(SourceRange(hole.end, p.end)) }
                return out
            }
        }
        return pieces
    }
}

/// Turns marks dropped while recording (captions, zoom hints, cuts, speed-ups) into edits.
public enum MarkEdits {
    public struct Options: Sendable {
        /// Cut stretches with no input longer than this (nil = keep everything).
        public var cutIdleLongerThan: Double?
        /// Default caption length when no later caption ends it.
        public var captionDuration: Double = 3.5

        public init(cutIdleLongerThan: Double? = nil, captionDuration: Double = 3.5) {
            self.cutIdleLongerThan = cutIdleLongerThan
            self.captionDuration = captionDuration
        }
    }

    /// Applies `marks` to `scene`. Zooms must already exist (auto-zoom runs first); zoom marks
    /// adjust the level of the zoom around the next click.
    public static func apply(_ scene: Scene, marks: [RecordingMark], events: RecordingEvents, duration: Double,
                             options: Options = Options()) -> Scene {
        var s = scene
        let marks = marks.sorted { $0.t < $1.t }

        // Captions: from the mark until the next caption, `value` seconds, or the default length.
        let captionMarks = marks.filter { $0.kind == .caption && !($0.text ?? "").isEmpty }
        for (i, m) in captionMarks.enumerated() {
            let next = i + 1 < captionMarks.count ? captionMarks[i + 1].t : duration
            let end = min(next, m.t + (m.value ?? options.captionDuration), duration)
            if end - m.t > 0.2 { s = Edits.addCaption(s, source: SourceRange(m.t, end), text: m.text!).0 }
        }

        // Zoom hints: set the level of the zoom covering the next click after the mark.
        let downClicks = events.downClicks
        for m in marks where m.kind == .zoom {
            guard let level = m.value, let click = downClicks.first(where: { $0.t >= m.t - 0.05 }),
                  let i = s.zooms.firstIndex(where: { $0.source.contains(SourceTime(click.t)) }) else { continue }
            s.zooms[i].level = min(max(level, 1.1), 4)
        }

        // Speed-ups between speed-start and speed-end (or the end).
        for (start, end) in pairs(marks, open: .speedStart, close: .speedEnd, duration: duration) {
            let speed = marks.first { $0.kind == .speedStart && $0.t == start }?.value ?? 2
            if end - start > 0.2 { s = Edits.setSpeed(s, source: SourceRange(start, end), speed: speed) }
        }

        // Explicit cuts, then idle cuts (never inside holds or captions' first half-second).
        var cuts = pairs(marks, open: .cutStart, close: .cutEnd, duration: duration).map { SourceRange($0.0, $0.1) }
        if let minGap = options.cutIdleLongerThan {
            let holds = marks.filter { $0.kind == .hold }.map { SourceRange($0.t, $0.t + max($0.value ?? 1, 0.1)) }
            let captionStarts = captionMarks.map { SourceRange($0.t - 0.2, $0.t + 1.2) }
            cuts += IdleDetector.idleRanges(events: events, duration: duration, minGap: minGap, keep: holds + captionStarts)
        }
        // Cut from the end backwards so earlier ranges stay valid.
        for cut in cuts.sorted(by: { $0.start > $1.start }) where cut.duration > 0.1 {
            if let next = try? Edits.removeSource(s, range: cut) { s = next }
        }
        return s
    }

    static func pairs(_ marks: [RecordingMark], open: RecordingMark.Kind, close: RecordingMark.Kind, duration: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var openAt: Double?
        for m in marks {
            if m.kind == open, openAt == nil { openAt = m.t }
            if m.kind == close, let a = openAt { out.append((a, m.t)); openAt = nil }
        }
        if let a = openAt { out.append((a, duration)) }
        return out
    }
}
