import Foundation

/// Where a tab dragged over a session's content would go, and what to light up while it is there (ADR-218).
/// Pure geometry, so the zones are tested here rather than with a pointer.
public enum PaneDropZones {
    /// One of a session's areas. A bottom area, when it comes, is another case and another edge.
    public enum Area: Equatable, Sendable { case main, right }

    /// A rectangle in the caller's coordinates. Its own type, because CGRect's helpers live in CoreGraphics,
    /// which ClinicCore does not import.
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var maxX: Double { x + width }
        public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
    }

    public struct Target: Equatable, Sendable {
        public var area: Area
        /// The rectangle to highlight.
        public var highlight: Rect
        public init(area: Area, highlight: Rect) { self.area = area; self.highlight = highlight }
    }

    /// How wide the main area's right-edge zone is: a quarter of the area, at least 140 pt, at most half.
    public static func edgeWidth(of main: Rect) -> Double {
        min(max(140, main.width * 0.25), main.width * 0.5)
    }

    /// The target under (`x`, `y`) for a tab now in `from`.
    ///
    /// - Over the right panel's content: the right panel.
    /// - With the panel hidden, over the right edge of the main area: the right panel, which the drop opens.
    /// - Anywhere else in the main area: the main area.
    ///
    /// Nil where a drop would change nothing (a tab over its own area) or where there is no area.
    public static func target(x: Double, y: Double, main: Rect, panel: Rect?, from: Area) -> Target? {
        let hit: Target? = {
            if let panel, panel.contains(x, y) { return Target(area: .right, highlight: panel) }
            guard main.contains(x, y) else { return nil }
            if panel == nil {
                let edge = edgeWidth(of: main)
                let zone = Rect(x: main.maxX - edge, y: main.y, width: edge, height: main.height)
                if zone.contains(x, y) { return Target(area: .right, highlight: zone) }
            }
            return Target(area: .main, highlight: main)
        }()
        guard let hit, hit.area != from else { return nil }
        return hit
    }
}
