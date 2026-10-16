import AppKit

// Vector-drawn icon; no image model, downloaded artwork, or runtime dependency.
let destination = CommandLine.arguments.dropFirst().first ?? "build/CalDock.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let outer = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 198, yRadius: 198)
        NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.28, blue: 0.31, alpha: 1), ending: NSColor(srgbRed: 0.08, green: 0.15, blue: 0.18, alpha: 1))!.draw(in: outer, angle: -70)
        let paper = NSBezierPath(roundedRect: NSRect(x: 227, y: 222, width: 570, height: 568), xRadius: 70, yRadius: 70)
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill(); paper.fill()
        NSGraphicsContext.saveGraphicsState()
        paper.addClip()
        NSColor(srgbRed: 0.96, green: 0.29, blue: 0.23, alpha: 1).setFill()
        NSRect(x: 226, y: 650, width: 572, height: 141).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        for x in [355, 625] { NSBezierPath(roundedRect: NSRect(x: x, y: 726, width: 44, height: 123), xRadius: 20, yRadius: 20).fill() }
        let number = "31" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 306, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.15, green: 0.24, blue: 0.27, alpha: 1)]
        let size = number.size(withAttributes: attrs)
        number.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 276), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
