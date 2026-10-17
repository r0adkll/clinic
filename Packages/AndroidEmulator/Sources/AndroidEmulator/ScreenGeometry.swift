import Foundation

/// Where a frame's pixels sit on the device, for drawing a frame and turning a click back into a touch.
///
/// Measured on emulator 36.6 (docs/Research/Embedded Android Emulator.md): a frame shows the natural
/// screen turned `quarterTurns` × 90° counter-clockwise, while touches land at natural-orientation
/// display pixels whatever the turn, so the pane undoes the turn itself. A folded foldable's region is
/// taken to be in natural display pixels too.
public struct ScreenGeometry: Sendable, Equatable {
    /// The natural display size in pixels.
    public let displayWidth: Int
    public let displayHeight: Int
    public let quarterTurns: Int
    /// The part of the display in use, in natural pixels; the whole display unless folded.
    public let region: EmulatorFrame.Region

    public init(displayWidth: Int, displayHeight: Int, quarterTurns: Int, folded: EmulatorFrame.Region? = nil) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.region = folded ?? EmulatorFrame.Region(x: 0, y: 0, width: displayWidth, height: displayHeight)
    }

    /// The visible part of a frame as fractions of its width and height (origin top left): the folded
    /// region turned the way the frame is. The whole frame when not folded.
    public var visibleFraction: (x: Double, y: Double, width: Double, height: Double) {
        let W = Double(displayWidth), H = Double(displayHeight)
        let x0 = Double(region.x) / W, x1 = Double(region.x + region.width) / W
        let y0 = Double(region.y) / H, y1 = Double(region.y + region.height) / H
        switch quarterTurns {
        case 1: return (y0, 1 - x1, y1 - y0, x1 - x0)
        case 2: return (1 - x1, 1 - y1, x1 - x0, y1 - y0)
        case 3: return (1 - y1, x0, y1 - y0, x1 - x0)
        default: return (x0, y0, x1 - x0, y1 - y0)
        }
    }

    /// The aspect ratio (width / height) the visible part has on screen.
    public var visibleAspect: Double {
        let w = Double(region.width), h = Double(region.height)
        return quarterTurns % 2 == 0 ? w / h : h / w
    }

    /// The touch for a point at fractions `u`, `v` (0…1, origin top left) across the visible part.
    public func devicePoint(u: Double, v: Double) -> (x: Int, y: Int) {
        let u = min(max(u, 0), 1), v = min(max(v, 0), 1)
        let (un, vn): (Double, Double) = switch quarterTurns {
        case 1: (1 - v, u)
        case 2: (1 - u, 1 - v)
        case 3: (v, 1 - u)
        default: (u, v)
        }
        return (region.x + Int((un * Double(region.width - 1)).rounded()),
                region.y + Int((vn * Double(region.height - 1)).rounded()))
    }
}
