import AppKit

let args = CommandLine.arguments
guard args.count == 2 else { exit(1) }

let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(2) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor.clear.setFill()
canvas.fill()

let base = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.106, alpha: 1).setFill()
base.fill()

let halo = NSBezierPath(ovalIn: NSRect(x: 184, y: 184, width: 656, height: 656))
NSColor(calibratedRed: 0.32, green: 0.70, blue: 0.76, alpha: 0.1).setFill()
halo.fill()

let wing = NSBezierPath()
wing.move(to: NSPoint(x: 235, y: 436))
wing.curve(to: NSPoint(x: 449, y: 612), controlPoint1: NSPoint(x: 341, y: 444), controlPoint2: NSPoint(x: 394, y: 493))
wing.curve(to: NSPoint(x: 701, y: 802), controlPoint1: NSPoint(x: 502, y: 727), controlPoint2: NSPoint(x: 564, y: 793))
wing.curve(to: NSPoint(x: 574, y: 594), controlPoint1: NSPoint(x: 615, y: 756), controlPoint2: NSPoint(x: 590, y: 677))
wing.curve(to: NSPoint(x: 463, y: 368), controlPoint1: NSPoint(x: 557, y: 507), controlPoint2: NSPoint(x: 541, y: 424))
wing.curve(to: NSPoint(x: 235, y: 340), controlPoint1: NSPoint(x: 404, y: 326), controlPoint2: NSPoint(x: 318, y: 320))
wing.curve(to: NSPoint(x: 410, y: 437), controlPoint1: NSPoint(x: 322, y: 350), controlPoint2: NSPoint(x: 375, y: 383))
wing.curve(to: NSPoint(x: 235, y: 436), controlPoint1: NSPoint(x: 352, y: 409), controlPoint2: NSPoint(x: 297, y: 402))
wing.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.486, green: 0.91, blue: 0.745, alpha: 1),
    NSColor(calibratedRed: 0.30, green: 0.46, blue: 1.0, alpha: 1)
])!
gradient.draw(in: wing, angle: -42)

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
try data.write(to: URL(fileURLWithPath: args[1]))
