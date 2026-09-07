import AppKit

// Deterministic vector artwork, rendered at every macOS icon resolution.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedRed: 0.24, green: 0.22, blue: 0.78, alpha: 1).setFill()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        tile.fill()
        NSColor(calibratedWhite: 1, alpha: 0.3).setStroke()
        tile.lineWidth = 12
        tile.stroke()
        NSColor.white.setFill()
        for (index, height) in [180.0, 350, 540, 350, 180].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 252 + Double(index) * 110, y: (1024 - height) / 2,
                width: 80, height: height), xRadius: 40, yRadius: 40).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Keep the standard Xcode app-icon catalog in sync with the ICNS source sizes.
if CommandLine.arguments.count > 2 {
    let catalog = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let filename = "icon_\(size)x\(size)\(suffix).png"
            try Data(contentsOf: output.appendingPathComponent(filename)).write(to: catalog.appendingPathComponent(filename))
            images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: catalog.appendingPathComponent("Contents.json"))
}
