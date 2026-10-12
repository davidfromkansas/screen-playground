import Testing
@testable import PlaygroundCore
@testable import Timeline

/// Mouse activity every 0.1 s over the given source ranges.
private func activity(_ ranges: [(Double, Double)]) -> [MouseMove] {
    ranges.flatMap { a, b in stride(from: a, through: b, by: 0.1).map { MouseMove(t: $0, x: 100, y: 100) } }
}

@Suite struct IdleDetectorTests {
    @Test func findsGapsWithPadding() {
        let events = RecordingEvents(moves: activity([(0, 2), (6, 8)]))
        let idle = IdleDetector.idleRanges(events: events, duration: 12, minGap: 1.5, padding: 0.4)
        // Gap 2…6 → 2.4…5.6; tail 8…12 → 8.4…11.6.
        #expect(idle.count == 2)
        #expect(abs(idle[0].start.seconds - 2.4) < 0.01 && abs(idle[0].end.seconds - 5.6) < 0.01)
        #expect(abs(idle[1].start.seconds - 8.4) < 0.01 && abs(idle[1].end.seconds - 11.6) < 0.01)
    }

    @Test func shortGapsAndHoldsAreKept() {
        let events = RecordingEvents(moves: activity([(0, 2), (3, 5), (9, 10)]))
        // 2…3 is under the threshold; 5…9 is held from 6 to 7.
        let idle = IdleDetector.idleRanges(events: events, duration: 10, minGap: 1.5, padding: 0.4, keep: [SourceRange(6, 7)])
        #expect(idle.map { [$0.start.seconds, $0.end.seconds].map { ($0 * 10).rounded() / 10 } } == [[5.4, 6], [7, 8.6]])
    }
}

@Suite struct CaptionTests {
    @Test func captionsSurviveCutsAndSpeedChanges() throws {
        var scene = Scene()
        scene.slices = Edits.initialSlices(duration: 20)
        scene = Edits.addCaption(scene, source: SourceRange(10, 14), text: "Hello").0
        scene = try Edits.removeSource(scene, range: SourceRange(2, 6))
        scene = Edits.setSpeed(scene, source: SourceRange(6, 10), speed: 2)
        // Still anchored in source time; output time follows the edit.
        #expect(scene.captions.first?.source == SourceRange(10, 14))
        let map = TimeMap(slices: scene.slices)
        // 0…2 (2s) + 6…10 at 2x (2s) → the caption starts at output 4.
        #expect(map.outputRanges(for: scene.captions[0].source).first?.start == OutputTime(4))
    }

    @Test func overlappingCaptionsAreTrimmed() {
        var scene = Scene()
        scene = Edits.addCaption(scene, source: SourceRange(0, 5), text: "A").0
        scene = Edits.addCaption(scene, source: SourceRange(3, 8), text: "B").0
        #expect(scene.captions.map(\.text) == ["A", "B"])
        #expect(scene.captions[0].source == SourceRange(0, 3))
        let (s2, id) = Edits.addCaption(scene, source: SourceRange(2, 9), text: "C")
        #expect(s2.captions.map(\.text) == ["A", "C"])
        #expect(Edits.removeCaption(s2, id: id).captions.count == 1)
    }
}

@Suite struct MarkEditsTests {
    func scene(duration: Double, zoomAround clickAt: Double? = nil) -> Scene {
        var s = Scene()
        s.slices = Edits.initialSlices(duration: duration)
        if let c = clickAt { s.zooms = [ZoomRange(source: SourceRange(c - 1, c + 2), level: 2)] }
        return s
    }

    @Test func captionsZoomsAndSpeed() {
        let events = RecordingEvents(moves: activity([(0, 12)]), clicks: [MouseClick(t: 5, x: 1, y: 1, phase: .down)])
        let marks = [
            RecordingMark(t: 1, kind: .caption, text: "Open the page"),
            RecordingMark(t: 4, kind: .caption, text: "Sign up", value: 2),
            RecordingMark(t: 4.8, kind: .zoom, value: 2.6),
            RecordingMark(t: 8, kind: .speedStart, value: 3),
            RecordingMark(t: 10, kind: .speedEnd),
        ]
        let s = MarkEdits.apply(scene(duration: 12, zoomAround: 5), marks: marks, events: events, duration: 12)
        #expect(s.captions.map(\.text) == ["Open the page", "Sign up"])
        #expect(s.captions[0].source == SourceRange(1, 4), "ends where the next caption starts")
        #expect(s.captions[1].source == SourceRange(4, 6), "value sets the length")
        #expect(s.zooms[0].level == 2.6)
        let map = TimeMap(slices: s.slices)
        #expect(abs(map.duration - (12 - 2 + 2.0 / 3)) < 0.01, "8…10 at 3x")
    }

    @Test func explicitAndIdleCutsKeepHolds() {
        let events = RecordingEvents(moves: activity([(0, 2), (8, 10)]))
        let marks = [
            RecordingMark(t: 3, kind: .hold, value: 1.5),
            RecordingMark(t: 9, kind: .cutStart),
            RecordingMark(t: 9.5, kind: .cutEnd),
        ]
        let s = MarkEdits.apply(scene(duration: 10), marks: marks, events: events, duration: 10,
                                options: MarkEdits.Options(cutIdleLongerThan: 1.5))
        let map = TimeMap(slices: s.slices)
        // Held 3…4.5 stays; idle 2.4…3 and 4.5…7.6 go; 9…9.5 goes.
        #expect(map.output(at: SourceTime(3.5)) != nil)
        #expect(map.output(at: SourceTime(6)) == nil)
        #expect(map.output(at: SourceTime(9.2)) == nil)
        #expect(map.duration < 6)
    }

    @Test func noMarksNoChange() {
        let base = scene(duration: 6)
        #expect(MarkEdits.apply(base, marks: [], events: RecordingEvents(), duration: 6) == base)
    }
}
