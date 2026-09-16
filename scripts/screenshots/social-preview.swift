// Composes .github/assets/social-preview.png from the dark hero (ADR-159): the app icon and tagline on the
// left, the sidebar and the start of the terminal on the right, 1280 x 640 as GitHub asks.
//
// usage: social-preview <app-icon.png> <hero-dark.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let icon = NSImage(contentsOfFile: args[1]), let heroImage = NSImage(contentsOfFile: args[2]),
      let hero = heroImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: social-preview <icon.png> <hero-dark.png> <out.png>\n".utf8)); exit(2)
}

// The icon's own palette (scripts/clinic-icon.svg), on a ground a shade darker than its tile so the tile reads.
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let ground = color(0x171513), cream = color(0xF2EBE3), coral = color(0xD97757)

// The capture carries a window shadow; the opaque bounding box is the window itself.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) where pixels[(y * w + x) * 4 + 3] > 250 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // A bitmap context's first buffer row is the image's top row, the same way round as CGImage cropping.
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let size = NSSize(width: 1280, height: 640)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
ground.setFill()
NSRect(origin: .zero, size: size).fill()

// Right: the top-left of the window (toolbar, sidebar cards, the edge of the terminal), clipped to a
// rounded card that runs off the right and bottom edges.
let window = opaqueBounds(hero)
let crop = CGRect(x: window.minX, y: window.minY, width: min(window.width, 1500), height: min(window.height, 1340))
if let part = hero.cropping(to: crop) {
    let scale = 560.0 / crop.height
    let frame = NSRect(x: 600, y: size.height - 60 - crop.height * scale, width: crop.width * scale, height: crop.height * scale)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
    NSImage(cgImage: part, size: frame.size).draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
}

// Left: icon, name, tagline.
icon.draw(in: NSRect(x: 72, y: 392, width: 128, height: 128))
func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]).draw(in: rect)
}
draw("Clinic", font: .systemFont(ofSize: 64, weight: .bold), color: cream, in: NSRect(x: 72, y: 290, width: 500, height: 84))
draw("All your Claude Code sessions, in good hands.", font: .systemFont(ofSize: 34, weight: .medium), color: cream,
     in: NSRect(x: 72, y: 170, width: 480, height: 110))
draw("A native Mac app", font: .systemFont(ofSize: 22, weight: .semibold), color: coral, in: NSRect(x: 72, y: 118, width: 480, height: 32))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[3]))
