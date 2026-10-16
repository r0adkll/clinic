import Foundation
import Testing
@testable import ClinicCore

@Suite struct PaneDropZonesTests {
    typealias R = PaneDropZones.Rect
    let main = R(x: 0, y: 0, width: 800, height: 600)
    let panel = R(x: 801, y: 0, width: 400, height: 600)

    @Test func theRightEdgeOfTheMainAreaOpensTheHiddenPanel() {
        let target = PaneDropZones.target(x: 750, y: 300, main: main, panel: nil, from: .main)
        #expect(target == .init(area: .right, highlight: R(x: 600, y: 0, width: 200, height: 600)))
    }

    @Test func theRestOfTheMainAreaIsNotADropForAMainTab() {
        #expect(PaneDropZones.target(x: 300, y: 300, main: main, panel: nil, from: .main) == nil)
    }

    @Test func aPanelTabDroppedOnTheMainAreaComesBack() {
        // With the panel showing there is no edge zone: the whole main area takes it.
        #expect(PaneDropZones.target(x: 700, y: 300, main: main, panel: panel, from: .right) == .init(area: .main, highlight: main))
    }

    @Test func overTheShowingPanelAMainTabGoesThere() {
        #expect(PaneDropZones.target(x: 900, y: 300, main: main, panel: panel, from: .main)?.area == .right)
        #expect(PaneDropZones.target(x: 900, y: 300, main: main, panel: panel, from: .right) == nil)
    }

    @Test func theEdgeIsAQuarterWithinItsBounds() {
        #expect(PaneDropZones.edgeWidth(of: R(x: 0, y: 0, width: 400, height: 1)) == 140)
        #expect(PaneDropZones.edgeWidth(of: R(x: 0, y: 0, width: 1200, height: 1)) == 300)
        #expect(PaneDropZones.edgeWidth(of: R(x: 0, y: 0, width: 200, height: 1)) == 100)
    }
}
