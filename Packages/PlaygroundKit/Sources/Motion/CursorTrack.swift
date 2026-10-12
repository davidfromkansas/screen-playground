import PlaygroundCore

/// Raw cursor data resampled into normalized content coordinates and source time,
/// with shake removal and cursor-type flicker suppression applied.
public struct CursorTrack: Sendable {
    public let times: [Double]
    public let points: [NormPoint]
    public let cursorIDs: [String?]
    /// Mouse-down intervals in source time.
    public let pressed: [SourceRange]
    public let clicks: [(t: Double, point: NormPoint)]

    public init(events: RecordingEvents, captureRect: ScreenRect, config: CursorConfig) {
        var times: [Double] = []
        var points: [NormPoint] = []
        var ids: [String?] = []
        times.reserveCapacity(events.moves.count)

        let geometry = events.geometry
        var gi = 0
        func rect(at t: Double) -> ScreenRect {
            guard !geometry.isEmpty else { return captureRect }
            while gi + 1 < geometry.count, geometry[gi + 1].t <= t { gi += 1 }
            return geometry[gi].t <= t ? geometry[gi].rect : captureRect
        }

        // Shake removal: ignore tiny movements that return near the anchor within the threshold.
        let jitterPoints = 2.5
        var anchor: (t: Double, x: Double, y: Double)?
        for m in events.moves {
            if config.removeShakes, let a = anchor {
                let d = ((m.x - a.x) * (m.x - a.x) + (m.y - a.y) * (m.y - a.y)).squareRoot()
                if d < jitterPoints && m.t - a.t < config.shakeThreshold { continue }
            }
            anchor = (m.t, m.x, m.y)
            let r = rect(at: m.t)
            times.append(m.t)
            points.append(r.normalize(x: m.x, y: m.y))
            ids.append(m.cursor)
        }

        // Carry cursor ids forward, then suppress changes shorter than 120 ms.
        var last: String? = nil
        for i in ids.indices {
            if let id = ids[i] { last = id } else { ids[i] = last }
        }
        if config.optimizeCursorChanges, ids.count > 2 {
            var i = 1
            while i < ids.count {
                guard ids[i] != ids[i - 1] else { i += 1; continue }
                let changeStart = times[i]
                var j = i
                while j < ids.count, ids[j] == ids[i] { j += 1 }
                if j < ids.count, times[j] - changeStart < 0.12, ids[j] == ids[i - 1] {
                    for k in i..<j { ids[k] = ids[i - 1] }
                }
                i = j
            }
        }

        self.times = times
        self.points = points
        self.cursorIDs = ids

        var pressed: [SourceRange] = []
        var clicks: [(Double, NormPoint)] = []
        var downAt: Double?
        for c in events.clicks where c.button == .left {
            let r = rect(at: c.t)
            if c.phase == .down {
                downAt = c.t
                clicks.append((c.t, r.normalize(x: c.x, y: c.y)))
            } else if let d = downAt {
                pressed.append(SourceRange(d, max(c.t, d + 0.05)))
                downAt = nil
            }
        }
        if let d = downAt { pressed.append(SourceRange(d, d + 0.15)) }
        self.pressed = pressed
        self.clicks = clicks
    }

    public var isEmpty: Bool { times.isEmpty }

    /// Index of the last sample at or before `t` (or 0).
    public func index(at t: Double) -> Int {
        guard !times.isEmpty, t > times[0] else { return 0 }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Linearly interpolated position at source time `t`.
    public func position(at t: Double) -> NormPoint {
        guard !times.isEmpty else { return .center }
        let i = index(at: t)
        guard i + 1 < times.count, t > times[i] else { return points[i] }
        let span = times[i + 1] - times[i]
        guard span > 0 else { return points[i] }
        let f = min(max((t - times[i]) / span, 0), 1)
        return points[i] + (points[i + 1] - points[i]) * f
    }

    public func cursorID(at t: Double) -> String? {
        guard !cursorIDs.isEmpty else { return nil }
        return cursorIDs[index(at: t)]
    }

    /// Source time of the last actual movement at or before `t`.
    public func lastMoveTime(at t: Double) -> Double {
        guard !times.isEmpty else { return 0 }
        return times[index(at: t)]
    }

    public func isPressed(at t: Double) -> Bool {
        // `pressed` is sorted by start; find the last interval starting at or before t.
        var lo = 0, hi = pressed.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if pressed[mid].start.seconds <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 && pressed[found].contains(SourceTime(t))
    }

    /// Time since the most recent click-down at or before `t`, for click effects.
    public func recentClick(at t: Double, within: Double) -> (age: Double, point: NormPoint)? {
        var result: (Double, NormPoint)?
        for c in clicks where c.t <= t && t - c.t <= within { result = (t - c.t, c.point) }
        return result
    }
}
