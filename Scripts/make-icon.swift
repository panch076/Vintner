// Renders Resources/AppIcon.icns. Run: swift Scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(colors: [NSColor(calibratedRed: 0.45, green: 0.05, blue: 0.18, alpha: 1),
                        NSColor(calibratedRed: 0.18, green: 0.02, blue: 0.12, alpha: 1)])!.draw(in: bg, angle: -90)

    // Wine glass
    let w = rect.width, x0 = rect.minX, y0 = rect.minY
    let bowl = NSBezierPath()
    bowl.move(to: NSPoint(x: x0 + w * 0.30, y: y0 + w * 0.80))
    bowl.line(to: NSPoint(x: x0 + w * 0.70, y: y0 + w * 0.80))
    bowl.curve(to: NSPoint(x: x0 + w * 0.5, y: y0 + w * 0.44),
               controlPoint1: NSPoint(x: x0 + w * 0.74, y: y0 + w * 0.56), controlPoint2: NSPoint(x: x0 + w * 0.62, y: y0 + w * 0.44))
    bowl.curve(to: NSPoint(x: x0 + w * 0.30, y: y0 + w * 0.80),
               controlPoint1: NSPoint(x: x0 + w * 0.38, y: y0 + w * 0.44), controlPoint2: NSPoint(x: x0 + w * 0.26, y: y0 + w * 0.56))
    NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()
    bowl.lineWidth = max(1, w * 0.035)
    bowl.stroke()

    let wine = NSBezierPath()
    wine.move(to: NSPoint(x: x0 + w * 0.315, y: y0 + w * 0.66))
    wine.line(to: NSPoint(x: x0 + w * 0.685, y: y0 + w * 0.66))
    wine.curve(to: NSPoint(x: x0 + w * 0.5, y: y0 + w * 0.47),
               controlPoint1: NSPoint(x: x0 + w * 0.67, y: y0 + w * 0.54), controlPoint2: NSPoint(x: x0 + w * 0.6, y: y0 + w * 0.47))
    wine.curve(to: NSPoint(x: x0 + w * 0.315, y: y0 + w * 0.66),
               controlPoint1: NSPoint(x: x0 + w * 0.4, y: y0 + w * 0.47), controlPoint2: NSPoint(x: x0 + w * 0.33, y: y0 + w * 0.54))
    NSColor(calibratedRed: 0.85, green: 0.15, blue: 0.3, alpha: 1).setFill()
    wine.fill()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: x0 + w * 0.5, y: y0 + w * 0.44))
    stem.line(to: NSPoint(x: x0 + w * 0.5, y: y0 + w * 0.2))
    stem.move(to: NSPoint(x: x0 + w * 0.36, y: y0 + w * 0.2))
    stem.line(to: NSPoint(x: x0 + w * 0.64, y: y0 + w * 0.2))
    stem.lineWidth = max(1, w * 0.035)
    stem.lineCapStyle = .round
    stem.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    if size <= 512 { try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try! render(size).write(to: out.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
print("ok")
