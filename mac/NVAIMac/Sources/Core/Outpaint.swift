import Foundation
import CoreGraphics

/// Outpainting wie unter Windows (jobs._prepare_outpaint, Referenzweg): Das Bild bekommt einen
/// grauen Rand, FLUX.2 Klein füllt ihn per Maske, danach kommt das Original zurück (OutpaintMask.swift).
enum Outpaint {
    /// So weit läuft das zurückgelegte Original weich in das neue Bild aus (Pixel).
    static let blend = 96
    static let maxEdge = 1024
    /// Obergrenze fürs Erweitern per Maske, darüber wird kleiner gerechnet und hochskaliert. Füllen mit
    /// Maske lief am M1 mit 8 GB bis 1184 × 880 (7,9 GB Spitze); 1488 × 704 gemessen in 120 s.
    static let maxPixels = 1_100_000
    /// Bleibt mehr als dieser Anteil des neuen Randes mittelgrau, rechnet JobQueue einmal nach.
    static let greyLimit = 0.02

    static func generationSize(_ width: Int, _ height: Int) -> (width: Int, height: Int) {
        let pixels = Double(width * height)
        guard pixels > Double(maxPixels) else { return (width, height) }
        let s = (Double(maxPixels) / pixels).squareRoot()
        func round16(_ v: Double) -> Int { max(256, Int((v / 16).rounded()) * 16) }
        return (round16(Double(width) * s), round16(Double(height) * s))
    }

    /// Anteil mittelgrauer Pixel (128 ± 4) im neuen Rand: Dort hat das Modell nicht gemalt.
    static func greyShare(_ result: CGImage, original: CGImage, _ e: Edges) -> Double {
        let width = result.width, height = result.height
        let sx = Double(width) / Double(original.width + e.left + e.right)
        let sy = Double(height) / Double(original.height + e.top + e.bottom)
        let x0 = Double(e.left) * sx, x1 = x0 + Double(original.width) * sx
        let y0 = Double(e.top) * sy, y1 = y0 + Double(original.height) * sy
        guard let px = rgba(result, width: width, height: height, draw: { ctx in
            ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
        }) else { return 0 }
        var border = 0, grey = 0
        for row in 0..<height {
            let y = Double(row) + 0.5
            for col in 0..<width {
                let x = Double(col) + 0.5
                if x >= x0 && x < x1 && y >= y0 && y < y1 { continue }
                border += 1
                let i = (row * width + col) * 4
                if (0..<3).allSatisfy({ abs(Int(px[i + $0]) - 128) <= 4 }) { grey += 1 }
            }
        }
        return border > 0 ? Double(grey) / Double(border) : 0
    }

    struct Edges: Sendable, Equatable {
        var left, top, right, bottom: Int
        var any: Bool { left + top + right + bottom > 0 }
    }

    /// Zielformat: Bild plus Rand, auf 16 gerundet.
    static func size(of image: CGImage, _ e: Edges) -> (width: Int, height: Int) {
        func round16(_ v: Int) -> Int { max(256, Int((Double(v) / 16).rounded()) * 16) }
        return (round16(image.width + e.left + e.right), round16(image.height + e.top + e.bottom))
    }

    /// Das Bild auf grauer Fläche (Mittelgrau wie ComfyUIs ImagePadForOutpaint).
    static func padded(_ image: CGImage, _ e: Edges) -> CGImage {
        let w = image.width + e.left + e.right, h = image.height + e.top + e.bottom
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext zählt y von unten.
        ctx.draw(image, in: CGRect(x: e.left, y: e.bottom, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func rgba(_ like: CGImage, width: Int, height: Int, draw: (CGContext) -> Void) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            draw(ctx)
            return true
        }
        return ok ? buffer : nil
    }

    static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
