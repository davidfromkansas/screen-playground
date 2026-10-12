import Testing
@testable import PlaygroundCore
@testable import Timeline

@Suite struct TimeMapTests {
    @Test func identity() {
        let map = TimeMap(slices: Edits.initialSlices(duration: 10))
        #expect(map.duration == 10)
        #expect(map.source(at: OutputTime(4))?.time == SourceTime(4))
        #expect(map.output(at: SourceTime(7)) == OutputTime(7))
    }

    @Test func speedAndCuts() {
        // [0,4) at 2x (2s), cut [4,6), [6,10) at 1x (4s)
        let slices = [Slice(source: SourceRange(0, 4), timeScale: 0.5), Slice(source: SourceRange(6, 10))]
        let map = TimeMap(slices: slices)
        #expect(map.duration == 6)
        #expect(map.source(at: OutputTime(1))?.time == SourceTime(2))
        #expect(map.source(at: OutputTime(3))?.time == SourceTime(7))
        #expect(map.output(at: SourceTime(5)) == nil)
        #expect(map.output(at: SourceTime(8)) == OutputTime(4))
        #expect(map.outputRanges(for: SourceRange(3, 7)) == [OutputRange(1.5, 2), OutputRange(2, 3)])
    }

    @Test func freezeSlice() {
        let slices = [Slice(source: SourceRange(0, 2)), Slice(source: SourceRange(2, 2.1), freezeDuration: 3)]
        let map = TimeMap(slices: slices)
        #expect(map.duration == 5)
        #expect(map.source(at: OutputTime(4))?.time == SourceTime(2))
    }

    @Test func roundTripProperty() {
        var rng = SystemRandomNumberGenerator()
        let slices = [Slice(source: SourceRange(0, 3), timeScale: 0.25), Slice(source: SourceRange(5, 9), timeScale: 2),
                      Slice(source: SourceRange(9, 12))]
        let map = TimeMap(slices: slices)
        for _ in 0..<500 {
            let o = OutputTime(Double.random(in: 0..<map.duration, using: &rng))
            let s = map.source(at: o)!.time
            let back = map.output(at: s)!
            #expect(abs(back.seconds - o.seconds) < 1e-9)
        }
    }
}

@Suite struct EditTests {
    func scene(_ d: Double = 10) -> Scene {
        var s = Scene()
        s.slices = Edits.initialSlices(duration: d)
        return s
    }

    @Test func splitAndRippleDelete() throws {
        var s = try Edits.split(scene(), at: OutputTime(4))
        #expect(s.slices.count == 2)
        #expect(s.slices[0].source == SourceRange(0, 4))
        s = try Edits.rippleDelete(s, at: OutputTime(6)) // removes source [4,6)
        #expect(TimeMap(slices: s.slices).duration == 8)
        #expect(s.slices[1].source == SourceRange(6, 10))
    }

    @Test func splitTooCloseToEdgeFails() {
        #expect(throws: EditError.tooShort) { try Edits.split(scene(), at: OutputTime(0.05)) }
    }

    @Test func speedAffectsDuration() {
        let s = Edits.setSpeed(scene(), sliceID: nil, speed: 2)
        #expect(TimeMap(slices: s.slices).duration == 5)
    }

    @Test func trimRespectsNeighbours() throws {
        var s = try Edits.split(scene(), at: OutputTime(5))
        s = try Edits.trim(s, sliceID: s.slices[1].id, start: SourceTime(2), recordingDuration: 10)
        #expect(s.slices[1].source.start == SourceTime(5))
        s = try Edits.trim(s, sliceID: s.slices[0].id, end: SourceTime(3), recordingDuration: 10)
        #expect(s.slices[0].source.end == SourceTime(3))
    }

    @Test func zoomsSurviveCuts() throws {
        var s = scene()
        let (withZoom, _) = try Edits.addZoom(s, at: OutputTime(6), duration: 2)
        s = withZoom
        s = try Edits.split(s, at: OutputTime(2))
        s = try Edits.rippleDelete(s, at: OutputTime(4)) // remove source [2,4)
        let ranges = TimeMap(slices: s.slices).outputRanges(for: s.zooms[0].source)
        #expect(ranges == [OutputRange(4, 6)])
    }

    @Test func addZoomInsideExistingFails() throws {
        let (s, _) = try Edits.addZoom(scene(), at: OutputTime(1), duration: 3)
        #expect(throws: EditError.outOfRange) { try Edits.addZoom(s, at: OutputTime(2)) }
    }

    @Test func removeSourceRanges() throws {
        var s = try Edits.removeSource(scene(), range: SourceRange(0, 1))
        s = try Edits.removeSource(s, range: SourceRange(9, 10))
        s = try Edits.removeSource(s, range: SourceRange(4, 5))
        #expect(s.slices.map(\.source) == [SourceRange(1, 4), SourceRange(5, 9)])
        #expect(TimeMap(slices: s.slices).duration == 7)
        #expect(throws: EditError.tooShort) { try Edits.removeSource(scene(), range: SourceRange(0, 10)) }
    }

    @Test func speedForSourceRange() {
        let s = Edits.setSpeed(scene(), source: SourceRange(2, 6), speed: 2)
        #expect(s.slices.count == 3)
        #expect(TimeMap(slices: s.slices).duration == 8)
    }

    @Test func undoHistory() {
        var h = EditHistory<Int>(initial: 0)
        h.commit(1, name: "a")
        h.commit(2, name: "b")
        #expect(h.undo() == 1)
        #expect(h.undo() == 0)
        #expect(h.undo() == nil)
        #expect(h.redo() == 1)
        h.commit(5, name: "c")
        #expect(h.redo() == nil)
        #expect(h.current == 5)
    }
}

@Suite struct AutoZoomTests {
    let cfg = AutoZoomConfig()

    @Test func singleClick() {
        let z = AutoZoom.generate(clicks: [.init(t: 3, point: NormPoint(0.3, 0.4))], duration: 10, config: cfg)
        #expect(z.count == 1)
        #expect(z[0].source.start.seconds == 3 - cfg.leadIn)
        #expect(z[0].source.end.seconds == 3 + cfg.leadOut)
        #expect(z[0].isAuto)
    }

    @Test func burstOfNearbyClicksIsOneZoom() {
        let clicks = (0..<5).map { AutoZoom.Click(t: 2 + Double($0) * 0.8, point: NormPoint(0.5 + Double($0) * 0.02, 0.5)) }
        let z = AutoZoom.generate(clicks: clicks, duration: 20, config: cfg)
        #expect(z.count == 1)
    }

    @Test func farApartInTimeAreSeparate() {
        let clicks = [AutoZoom.Click(t: 1, point: .center), AutoZoom.Click(t: 10, point: .center)]
        #expect(AutoZoom.generate(clicks: clicks, duration: 20, config: cfg).count == 2)
    }

    @Test func farApartInSpaceDoNotOverlap() {
        let clicks = [AutoZoom.Click(t: 1, point: NormPoint(0.1, 0.1)), AutoZoom.Click(t: 1.5, point: NormPoint(0.9, 0.9))]
        let z = AutoZoom.generate(clicks: clicks, duration: 20, config: cfg)
        #expect(z.count == 2)
        #expect(z[0].source.end <= z[1].source.start)
    }

    @Test func clampedToRecording() {
        let z = AutoZoom.generate(clicks: [.init(t: 0.2, point: .center), .init(t: 9.9, point: .center)], duration: 10, config: cfg)
        #expect(z.first!.source.start.seconds == 0)
        #expect(z.last!.source.end.seconds == 10)
    }

    @Test func regenerateKeepsManualZooms() {
        var s = Scene()
        s.zooms = [ZoomRange(source: SourceRange(0.5, 4), mode: .manual)]
        let out = AutoZoom.regenerate(s, clicks: [.init(t: 2, point: .center), .init(t: 9, point: .center)], duration: 12, config: cfg)
        #expect(out.zooms.count == 2)
        #expect(out.zooms.contains { $0.mode == .manual })
    }
}

@Suite struct ShortcutDetectorTests {
    func key(_ t: Double, _ code: Int, _ chars: String, _ mods: Modifiers, repeating: Bool = false) -> KeyStroke {
        KeyStroke(t: t, keyCode: code, characters: chars, charactersIgnoringModifiers: chars, modifiers: mods, isRepeat: repeating)
    }

    @Test func picksShortcutsNotTyping() {
        let keys = [
            key(0.0, 4, "h", []), key(0.1, 34, "i", []),               // typing → ignored
            key(1.0, 1, "s", [.command]),                               // ⌘S
            key(2.0, 40, "k", [.command, .shift]),                      // ⇧⌘K
            key(3.0, 36, "\r", []),                                     // Return alone → only with single keys
            key(3.5, 1, "s", [.command], repeating: true),              // auto-repeat → ignored
            key(4.0, 123, "", [.option, .shift]),                       // ⌥⇧←
        ]
        let plain = ShortcutDetector.detect(keys, includeSingleKeys: false)
        #expect(plain.map(\.text) == ["⌘ S", "⇧ ⌘ K", "⌥ ⇧ ←"])
        let withSingles = ShortcutDetector.detect(keys, includeSingleKeys: true)
        #expect(withSingles.map(\.text).contains("↩"))
        #expect(ShortcutDetector.detect(keys, includeSingleKeys: false, hidden: [2]).map(\.text) == ["⇧ ⌘ K", "⌥ ⇧ ←"])
    }

    @Test func visibilityWindowAndFades() {
        let s = [ShortcutEvent(t: 1, index: 0, keys: ["⌘", "S"])]
        #expect(ShortcutDetector.active(s, at: 0.9) == nil)
        #expect(ShortcutDetector.active(s, at: 1.5)?.1 == 1)
        #expect((ShortcutDetector.active(s, at: 2.1)?.1 ?? 1) < 0.5)
        #expect(ShortcutDetector.active(s, at: 2.3) == nil)
    }
}
