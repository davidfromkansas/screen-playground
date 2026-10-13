import PlaygroundCore
@testable import Screen_Playground
import Testing

@MainActor
@Suite struct CropEditorTests {
    let full = NormRect.full
    func close(_ a: NormRect, _ b: NormRect) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    @Test func edgesAndCornersResize() {
        let r = CropEditor.resize(full, handle: .top, dx: 0, dy: 0.1, lockedAspect: nil, sourceAspect: 16.0 / 9)
        #expect(close(r, NormRect(x: 0, y: 0.1, width: 1, height: 0.9)))
        let c = CropEditor.resize(full, handle: .bottomRight, dx: -0.25, dy: -0.5, lockedAspect: nil, sourceAspect: 16.0 / 9)
        #expect(close(c, NormRect(x: 0, y: 0, width: 0.75, height: 0.5)))
    }

    @Test func staysInsideAndAboveMinimumSize() {
        let r = CropEditor.resize(full, handle: .left, dx: 5, dy: 0, lockedAspect: nil, sourceAspect: 1)
        #expect(r.width >= CropEditor.minSize - 1e-9 && r.x + r.width <= 1)
        let out = CropEditor.resize(NormRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), handle: .body, dx: 2, dy: -2, lockedAspect: nil, sourceAspect: 1)
        #expect(close(out, NormRect(x: 0.5, y: 0, width: 0.5, height: 0.5)), "moving is clamped to the frame")
    }

    @Test func edgesSnapToTheFrame() {
        let r = CropEditor.resize(NormRect(x: 0.1, y: 0, width: 0.9, height: 1), handle: .left, dx: -0.095, dy: 0, lockedAspect: nil, sourceAspect: 1)
        #expect(r.x == 0)
    }

    @Test func lockedAspectHoldsInPixels() {
        // 16:9 source, square crop: normalized width = height × 9/16.
        let r = CropEditor.resize(NormRect(x: 0.2, y: 0.1, width: 0.3, height: 0.5), handle: .bottomRight, dx: 0.1, dy: 0,
                                  lockedAspect: 1, sourceAspect: 16.0 / 9)
        #expect(abs((r.width * 16 / 9) / r.height - 1) < 1e-6)
        #expect(r.x == 0.2 && r.y == 0.1, "anchored at the opposite corner")
        let c = CropEditor.centered(aspect: 9.0 / 16, sourceAspect: 16.0 / 9)
        #expect(abs(c.height - 1) < 1e-9 && abs(c.x + c.width / 2 - 0.5) < 1e-9)
    }
}
