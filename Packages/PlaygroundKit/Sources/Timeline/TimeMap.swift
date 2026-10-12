import PlaygroundCore

/// Maps between output (edited) time and source (recorded) time for an ordered list of slices.
/// Built once per edit; all lookups are O(log n).
public struct TimeMap: Sendable {
    public let slices: [Slice]
    /// Output start time of each slice (prefix sums of output durations).
    public let outputStarts: [Double]
    public let duration: Double

    public init(slices: [Slice]) {
        self.slices = slices
        var starts: [Double] = []
        starts.reserveCapacity(slices.count)
        var acc = 0.0
        for s in slices {
            starts.append(acc)
            acc += s.outputDuration
        }
        outputStarts = starts
        duration = acc
    }

    public var outputDuration: OutputTime { OutputTime(duration) }

    /// Index of the slice playing at output time `t` (clamped to the valid range).
    public func sliceIndex(at t: OutputTime) -> Int? {
        guard !slices.isEmpty else { return nil }
        var lo = 0, hi = slices.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if outputStarts[mid] <= t.seconds { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The source time shown at output time `t`.
    public func source(at t: OutputTime) -> (index: Int, time: SourceTime)? {
        guard let i = sliceIndex(at: t) else { return nil }
        let s = slices[i]
        if s.freezeDuration != nil { return (i, s.source.start) }
        let local = min(max(t.seconds - outputStarts[i], 0), s.outputDuration)
        let src = s.source.start.seconds + local / s.timeScale
        return (i, SourceTime(min(src, s.source.end.seconds)))
    }

    /// The output time at which source time `t` plays, or nil if it was cut.
    public func output(at t: SourceTime) -> OutputTime? {
        for (i, s) in slices.enumerated() where s.freezeDuration == nil && s.source.contains(t) {
            return OutputTime(outputStarts[i] + (t.seconds - s.source.start.seconds) * s.timeScale)
        }
        // Allow the exact end of the last slice.
        if let last = slices.last, last.freezeDuration == nil, t == last.source.end {
            return OutputTime(duration)
        }
        return nil
    }

    /// Output intervals where any part of a source range is visible (one per overlapping slice).
    public func outputRanges(for range: SourceRange) -> [OutputRange] {
        var out: [OutputRange] = []
        for (i, s) in slices.enumerated() where s.freezeDuration == nil {
            let a = max(range.start.seconds, s.source.start.seconds)
            let b = min(range.end.seconds, s.source.end.seconds)
            guard b > a else { continue }
            let oa = outputStarts[i] + (a - s.source.start.seconds) * s.timeScale
            let ob = outputStarts[i] + (b - s.source.start.seconds) * s.timeScale
            out.append(OutputRange(oa, ob))
        }
        return out
    }

    /// Source intervals shown during an output range (one per overlapping slice, in order).
    public func sourceRanges(for range: OutputRange) -> [SourceRange] {
        var out: [SourceRange] = []
        for (i, s) in slices.enumerated() where s.freezeDuration == nil {
            let a = max(range.start.seconds, outputStarts[i])
            let b = min(range.end.seconds, outputStarts[i] + s.outputDuration)
            guard b > a else { continue }
            let sa = s.source.start.seconds + (a - outputStarts[i]) / s.timeScale
            let sb = s.source.start.seconds + (b - outputStarts[i]) / s.timeScale
            out.append(SourceRange(sa, min(sb, s.source.end.seconds)))
        }
        return out
    }

    /// The slice at output time `t`, if any.
    public func slice(at t: OutputTime) -> Slice? { sliceIndex(at: t).map { slices[$0] } }

    /// Output time of each cut boundary (excluding 0 and the end).
    public var cutPoints: [OutputTime] { outputStarts.dropFirst().map { OutputTime($0) } }
}
