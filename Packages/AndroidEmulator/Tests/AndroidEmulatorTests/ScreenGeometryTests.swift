import Testing
@testable import AndroidEmulator

@Suite struct ScreenGeometryTests {
    let w = 1080, h = 2160

    @Test func uprightMapsStraightThrough() {
        let g = ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: 0)
        #expect(g.devicePoint(u: 0, v: 0) == (0, 0))
        #expect(g.devicePoint(u: 1, v: 1) == (1079, 2159))
        #expect(g.visibleAspect == 0.5)
    }

    /// Turned once (counter-clockwise), the frame's top left shows the natural top right.
    @Test func aQuarterTurnIsUndone() {
        let g = ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: 1)
        #expect(g.devicePoint(u: 0, v: 0) == (1079, 0))
        #expect(g.devicePoint(u: 1, v: 0) == (1079, 2159))
        #expect(g.devicePoint(u: 0, v: 1) == (0, 0))
        #expect(g.visibleAspect == 2)
    }

    @Test func halfAndThreeQuarterTurns() {
        let half = ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: 2)
        #expect(half.devicePoint(u: 0, v: 0) == (1079, 2159))
        let three = ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: 3)
        #expect(three.devicePoint(u: 0, v: 0) == (0, 2159))
        #expect(three.devicePoint(u: 1, v: 1) == (1079, 0))
    }

    @Test func turnsAreTakenModuloFour() {
        #expect(ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: -1).quarterTurns == 3)
        #expect(ScreenGeometry(displayWidth: w, displayHeight: h, quarterTurns: 5).quarterTurns == 1)
    }

    /// Folded: only the region is visible and touches stay inside it.
    @Test func aFoldedRegionCropsAndOffsets() {
        let fold = EmulatorFrame.Region(x: 1000, y: 0, width: 1000, height: 2000)
        let g = ScreenGeometry(displayWidth: 2000, displayHeight: 2000, quarterTurns: 0, folded: fold)
        #expect(g.visibleFraction == (0.5, 0, 0.5, 1))
        #expect(g.devicePoint(u: 0, v: 0) == (1000, 0))
        #expect(g.devicePoint(u: 1, v: 1) == (1999, 1999))
        let turned = ScreenGeometry(displayWidth: 2000, displayHeight: 2000, quarterTurns: 1, folded: fold)
        #expect(turned.visibleFraction == (0, 0, 1, 0.5))
    }
}
