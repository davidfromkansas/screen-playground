import PlaygroundCore

public enum EditError: Error, Equatable {
    case outOfRange
    case tooShort
    case notFound
}

/// Pure edit operations on a scene. Each returns a new value; undo stores snapshots.
public enum Edits {
    public static let minimumSliceDuration = 0.1
    public static let minimumZoomDuration = 0.1
    public static let minimumLayoutDuration = 0.5

    /// One slice covering the whole recording.
    public static func initialSlices(duration: Double) -> [Slice] {
        [Slice(source: SourceRange(0, duration))]
    }

    /// Splits the slice under output time `t` into two.
    public static func split(_ scene: Scene, at t: OutputTime) throws -> Scene {
        let map = TimeMap(slices: scene.slices)
        guard let (i, src) = map.source(at: t) else { throw EditError.outOfRange }
        let s = scene.slices[i]
        guard s.freezeDuration == nil else { throw EditError.outOfRange }
        guard src.seconds - s.source.start.seconds >= minimumSliceDuration,
              s.source.end.seconds - src.seconds >= minimumSliceDuration else { throw EditError.tooShort }
        var left = s, right = s
        left.source.end = src
        right.id = makeItemID()
        right.source.start = src
        var out = scene
        out.slices.replaceSubrange(i...i, with: [left, right])
        return out
    }

    /// Removes a slice entirely.
    public static func remove(_ scene: Scene, sliceID: ItemID) throws -> Scene {
        guard scene.slices.count > 1 else { throw EditError.tooShort }
        var out = scene
        guard let i = out.slices.firstIndex(where: { $0.id == sliceID }) else { throw EditError.notFound }
        out.slices.remove(at: i)
        return out
    }

    /// Screen Studio's "X": removes from the playhead back to the previous cut.
    public static func rippleDelete(_ scene: Scene, at t: OutputTime) throws -> Scene {
        let map = TimeMap(slices: scene.slices)
        guard let (i, src) = map.source(at: t) else { throw EditError.outOfRange }
        let s = scene.slices[i]
        var out = scene
        if src.seconds - s.source.start.seconds < minimumSliceDuration { throw EditError.tooShort }
        if s.source.end.seconds - src.seconds < minimumSliceDuration {
            return try remove(scene, sliceID: s.id)
        }
        out.slices[i].source.start = src
        return out
    }

    /// Moves a slice's source in/out points (dragging clip edges).
    public static func trim(_ scene: Scene, sliceID: ItemID, start: SourceTime? = nil, end: SourceTime? = nil,
                            recordingDuration: Double) throws -> Scene {
        var out = scene
        guard let i = out.slices.firstIndex(where: { $0.id == sliceID }) else { throw EditError.notFound }
        var s = out.slices[i]
        // Neighbours in source order bound how far an edge can move.
        let lowerBound = i > 0 ? out.slices[i - 1].source.end.seconds : 0
        let upperBound = i < out.slices.count - 1 ? out.slices[i + 1].source.start.seconds : recordingDuration
        if let start { s.source.start = SourceTime(min(max(start.seconds, lowerBound), s.source.end.seconds - minimumSliceDuration)) }
        if let end { s.source.end = SourceTime(max(min(end.seconds, upperBound), s.source.start.seconds + minimumSliceDuration)) }
        out.slices[i] = s
        return out
    }

    public static func updateSlice(_ scene: Scene, sliceID: ItemID, _ change: (inout Slice) -> Void) throws -> Scene {
        var out = scene
        guard let i = out.slices.firstIndex(where: { $0.id == sliceID }) else { throw EditError.notFound }
        change(&out.slices[i])
        return out
    }

    /// Sets playback speed (2 = twice as fast) for one or all slices.
    public static func setSpeed(_ scene: Scene, sliceID: ItemID?, speed: Double) -> Scene {
        var out = scene
        for i in out.slices.indices where sliceID == nil || out.slices[i].id == sliceID {
            out.slices[i].timeScale = 1 / max(speed, 0.05)
        }
        return out
    }

    /// Restores a single full-length slice, keeping per-slice settings of the first one.
    public static func resetCuts(_ scene: Scene, recordingDuration: Double) -> Scene {
        var out = scene
        var base = scene.slices.first ?? Slice(source: SourceRange(0, recordingDuration))
        base.source = SourceRange(0, recordingDuration)
        base.timeScale = 1
        base.freezeDuration = nil
        out.slices = [base]
        return out
    }

    /// Removes a source range from every slice it touches (splitting slices as needed).
    /// Used for transcript edits, filler-word removal and scripted cuts.
    public static func removeSource(_ scene: Scene, range: SourceRange) throws -> Scene {
        var out = scene
        var slices: [Slice] = []
        for s in scene.slices {
            guard s.freezeDuration == nil, s.source.overlaps(range) else { slices.append(s); continue }
            if range.start.seconds - s.source.start.seconds >= minimumSliceDuration / 2 {
                var left = s
                left.source.end = range.start
                slices.append(left)
            }
            if s.source.end.seconds - range.end.seconds >= minimumSliceDuration / 2 {
                var right = s
                right.id = makeItemID()
                right.source.start = range.end
                slices.append(right)
            }
        }
        guard !slices.isEmpty else { throw EditError.tooShort }
        out.slices = slices
        return out
    }

    /// Sets the speed of a source range, splitting slices at its boundaries.
    public static func setSpeed(_ scene: Scene, source range: SourceRange, speed: Double) -> Scene {
        var out = scene
        var slices: [Slice] = []
        for s in scene.slices {
            guard s.freezeDuration == nil, s.source.overlaps(range) else { slices.append(s); continue }
            let a = max(s.source.start.seconds, range.start.seconds), b = min(s.source.end.seconds, range.end.seconds)
            if a - s.source.start.seconds > 0.001 { var l = s; l.source.end = SourceTime(a); slices.append(l) }
            var mid = s
            mid.id = makeItemID()
            mid.source = SourceRange(a, b)
            mid.timeScale = 1 / max(speed, 0.05)
            slices.append(mid)
            if s.source.end.seconds - b > 0.001 { var r = s; r.id = makeItemID(); r.source.start = SourceTime(b); slices.append(r) }
        }
        out.slices = slices
        return out
    }

    // MARK: Zooms

    /// Adds a zoom at output time `t`, sized to fit before the next zoom.
    public static func addZoom(_ scene: Scene, at t: OutputTime, duration: Double = 2, level: Double = 2) throws -> (Scene, ItemID) {
        let map = TimeMap(slices: scene.slices)
        guard let (_, src) = map.source(at: t) else { throw EditError.outOfRange }
        var end = src.seconds + duration
        if let next = scene.zooms.map(\.source.start.seconds).filter({ $0 > src.seconds }).min() {
            end = min(end, next)
        }
        if scene.zooms.contains(where: { $0.source.contains(src) }) { throw EditError.outOfRange }
        guard end - src.seconds >= minimumZoomDuration else { throw EditError.tooShort }
        let zoom = ZoomRange(source: SourceRange(src.seconds, end), level: level)
        var out = scene
        out.zooms.append(zoom)
        out.zooms.sort { $0.source.start < $1.source.start }
        return (out, zoom.id)
    }

    public static func updateZoom(_ scene: Scene, id: ItemID, _ change: (inout ZoomRange) -> Void) throws -> Scene {
        var out = scene
        guard let i = out.zooms.firstIndex(where: { $0.id == id }) else { throw EditError.notFound }
        change(&out.zooms[i])
        if out.zooms[i].source.duration < minimumZoomDuration {
            out.zooms[i].source.end = out.zooms[i].source.start + minimumZoomDuration
        }
        out.zooms.sort { $0.source.start < $1.source.start }
        return out
    }

    public static func removeZoom(_ scene: Scene, id: ItemID) -> Scene {
        var out = scene
        out.zooms.removeAll { $0.id == id }
        return out
    }

    public static func applyZoomLevelToAll(_ scene: Scene, level: Double) -> Scene {
        var out = scene
        for i in out.zooms.indices { out.zooms[i].level = level }
        return out
    }

    // MARK: Captions (source-time ranges, so cuts and speed changes never shift them)

    /// Adds a caption; overlapping captions are trimmed so only one shows at a time.
    public static func addCaption(_ scene: Scene, source: SourceRange, text: String) -> (Scene, ItemID) {
        var s = scene
        let caption = CaptionRange(source: source, text: text)
        s.captions = s.captions.compactMap { c in
            var c = c
            if c.source.start < source.start && c.source.end > source.start { c.source = SourceRange(c.source.start.seconds, source.start.seconds) }
            else if c.source.start >= source.start && c.source.start < source.end {
                guard c.source.end > source.end else { return nil }
                c.source = SourceRange(source.end.seconds, c.source.end.seconds)
            }
            return c.source.duration > 0.05 ? c : nil
        }
        s.captions.append(caption)
        s.captions.sort { $0.source.start < $1.source.start }
        return (s, caption.id)
    }

    public static func updateCaption(_ scene: Scene, id: ItemID, _ change: (inout CaptionRange) -> Void) -> Scene {
        var s = scene
        if let i = s.captions.firstIndex(where: { $0.id == id }) { change(&s.captions[i]) }
        return s
    }

    public static func removeCaption(_ scene: Scene, id: ItemID) -> Scene {
        var s = scene
        s.captions.removeAll { $0.id == id }
        return s
    }
}
