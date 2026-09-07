import SwiftUI

/// Terminal on the left, a page on the right, with a draggable divider. The right width is clamped so
/// neither side can overflow the window, and it is remembered across launches.
struct RightSplit<Left: View, Right: View>: View {
    @AppStorage("ClinicRightPaneWidth") private var rightWidth: Double = 480
    let leftMin: CGFloat
    let rightMin: CGFloat
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right
    @State private var dragStart: Double?

    init(leftMin: CGFloat = 360, rightMin: CGFloat = 320, @ViewBuilder left: @escaping () -> Left, @ViewBuilder right: @escaping () -> Right) {
        self.leftMin = leftMin; self.rightMin = rightMin; self.left = left; self.right = right
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let maxRight = max(rightMin, total - leftMin)
            let width = min(max(CGFloat(rightWidth), rightMin), maxRight)
            HStack(spacing: 0) {
                left().frame(width: max(0, total - width))
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    .overlay(Rectangle().fill(.clear).frame(width: 9).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStart == nil { dragStart = Double(width) }
                                rightWidth = Double(min(max(CGFloat(dragStart!) - v.translation.width, rightMin), maxRight))
                            }
                            .onEnded { _ in dragStart = nil }))
                right().frame(width: width)
            }
        }
    }
}
