import Cocoa
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        let bg = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 195, yRadius: 195)
        NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.20, blue: 0.33, alpha: 1), ending: NSColor(srgbRed: 0.025, green: 0.055, blue: 0.12, alpha: 1))!.draw(in: bg, angle: -70)
        let chassis = NSBezierPath(roundedRect: NSRect(x: 270, y: 205, width: 375, height: 625), xRadius: 60, yRadius: 60)
        NSColor(srgbRed: 0.73, green: 0.90, blue: 1, alpha: 1).setStroke(); chassis.lineWidth = 23; chassis.stroke()
        for (y, c) in [(665, NSColor.systemCyan), (485, NSColor.systemPurple), (305, NSColor.systemPink)] {
            let ring = NSBezierPath(ovalIn: NSRect(x: 377, y: y - 62, width: 145, height: 145))
            c.setStroke(); ring.lineWidth = 22; ring.stroke()
            c.withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: NSRect(x: 400, y: y - 39, width: 99, height: 99)).fill()
        }
        let badge = NSBezierPath(roundedRect: NSRect(x: 580, y: 160, width: 290, height: 290), xRadius: 85, yRadius: 85)
        NSColor(srgbRed: 0.15, green: 0.79, blue: 0.75, alpha: 1).setFill(); badge.fill()
        NSColor(srgbRed: 0.015, green: 0.13, blue: 0.22, alpha: 1).setFill()
        for (x, h) in [(627, 65), (674, 145), (721, 205), (768, 110), (815, 60)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 305 - h / 2, width: 22, height: h), xRadius: 11, yRadius: 11).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(filename))
    }
}
