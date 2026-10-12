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
}
