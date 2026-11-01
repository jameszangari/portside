// Renders the Portside DMG window background: sailcloth field, an orange
// arrow pointing from the app (top) into a drop zone holding the
// Applications shortcut (bottom). Positions must match scripts/make-dmg.sh.
// Usage: swift scripts/DMGBackground.swift <out@1x.png> <out@2x.png>
import AppKit

let width: CGFloat = 540
let height: CGFloat = 560

let sailcloth = NSColor(srgbRed: 0xF4 / 255, green: 0xEE / 255, blue: 0xDF / 255, alpha: 1)
let navy = NSColor(srgbRed: 0x10 / 255, green: 0x28 / 255, blue: 0x3F / 255, alpha: 1)
let orange = NSColor(srgbRed: 0xF0 / 255, green: 0x6A / 255, blue: 0x42 / 255, alpha: 1)

/// Layout is described top-down like Finder icon positions; AppKit draws bottom-up.
func flipped(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
}

func flipped(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: height - point.y)
}

func draw() {
    sailcloth.setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()

    let zone = NSBezierPath(roundedRect: flipped(CGRect(x: 70, y: 300, width: 400, height: 230)),
                            xRadius: 24, yRadius: 24)
    navy.withAlphaComponent(0.07).setFill()
    zone.fill()
    navy.withAlphaComponent(0.12).setStroke()
    zone.lineWidth = 1
    zone.stroke()

    let arrow = NSBezierPath()
    let shaftHalf: CGFloat = 13
    let headHalf: CGFloat = 38
    arrow.move(to: flipped(CGPoint(x: 270 - shaftHalf, y: 262)))
    arrow.line(to: flipped(CGPoint(x: 270 + shaftHalf, y: 262)))
    arrow.line(to: flipped(CGPoint(x: 270 + shaftHalf, y: 300)))
    arrow.line(to: flipped(CGPoint(x: 270 + headHalf, y: 300)))
    arrow.line(to: flipped(CGPoint(x: 270, y: 340)))
    arrow.line(to: flipped(CGPoint(x: 270 - headHalf, y: 300)))
    arrow.line(to: flipped(CGPoint(x: 270 - shaftHalf, y: 300)))
    arrow.close()
    orange.setFill()
    arrow.fill()
}

func render(scale: CGFloat, to path: String) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: DMGBackground <out@1x.png> <out@2x.png>\n".data(using: .utf8)!)
    exit(2)
}
do {
    try render(scale: 1, to: args[1])
    try render(scale: 2, to: args[2])
} catch {
    FileHandle.standardError.write("DMGBackground: \(error)\n".data(using: .utf8)!)
    exit(1)
}
