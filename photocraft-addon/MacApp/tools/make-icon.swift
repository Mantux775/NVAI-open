import AppKit

// App-Symbol als .iconset für iconutil: das Funkeln des Panel-Logos auf blau-violettem Verlauf.
// Randlos quadratisch – macOS 26 legt die abgerundete Form selbst darüber.
//   swift tools/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Sterne aus panel/index.html (24er-Raster, y nach unten), mittig gesetzt und etwas verkleinert.
let stars: [[(CGFloat, CGFloat)]] = [
    [(11, 2.5), (12.8, 7.7), (18, 9.5), (12.8, 11.3), (11, 16.5), (9.2, 11.3), (4, 9.5), (9.2, 7.7)],
    [(18.5, 14), (19.4, 16.6), (22, 17.5), (19.4, 18.4), (18.5, 21), (17.6, 18.4), (15, 17.5), (17.6, 16.6)],
]

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let square = NSRect(x: 0, y: 0, width: s, height: s)
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.58, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.45, green: 0.30, blue: 0.90, alpha: 1)])!
        .draw(in: square, angle: -45)

    // 24er-Raster auf die Fläche: Mitte der Sterne (13 | 11,75) auf die Bildmitte, Faktor 0,9.
    let scale = s / 24 * 0.9
    func point(_ p: (CGFloat, CGFloat)) -> NSPoint {
        NSPoint(x: s / 2 + (p.0 - 13) * scale, y: s / 2 - (p.1 - 11.75) * scale)
    }
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSColor.white.setFill()
    for star in stars {
        let path = NSBezierPath()
        path.move(to: point(star[0]))
        for p in star.dropFirst() { path.line(to: point(p)) }
        path.close()
        path.fill()
    }
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * factor).write(to: out.appendingPathComponent(name))
    }
}
print("Symbol: \(out.path)")
