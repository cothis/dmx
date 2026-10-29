import AppKit

// Code-native artwork: three container blocks on a quiet, opaque app-icon ground.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        NSAffineTransform(transform: AffineTransform(scaleByX: s, byY: s)).concat()
        NSColor(srgbRed: 0.12, green: 0.16, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196).fill()
        NSColor(srgbRed: 0.79, green: 0.91, blue: 0.86, alpha: 1).setFill()
        for rect in [NSRect(x: 228, y: 278, width: 260, height: 210),
                     NSRect(x: 536, y: 278, width: 260, height: 210),
                     NSRect(x: 382, y: 536, width: 260, height: 210)] {
            NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
