import Foundation
import CoreGraphics

/// Outpainting wie unter Windows (jobs._prepare_outpaint, Referenzweg): Das Bild bekommt einen
/// grauen Rand und geht als Referenz an FLUX.2 Klein, danach wird das Original mit weichem
/// Übergang zurückgelegt. Unter Windows gemessen: nahtlos, der alte Teil unverändert – der
/// Maskenweg ließ dort eine harte Kante an der alten Bildgrenze.
enum Outpaint {
    /// Anweisung vor dem Prompt, gleichlautend mit NV-AI für Windows.
    static let instruction = "Extend the picture into the flat grey border: continue the scene seamlessly "
        + "with the same light, perspective and style, and keep the existing picture unchanged."
    /// So weit läuft das zurückgelegte Original weich in das neue Bild aus (Pixel).
    static let blend = 96
    static let maxEdge = 1024
    /// FLUX.2 Klein 4B führt die Szene nur bei kleiner Bildgröße weiter. Gemessen am M1: 768 × 512 nahtlos,
    /// 1248 × 832 mit eingeklebtem Fremdbild und grauen Resten (beide Seeds). Darüber wird kleiner gerechnet
    /// und hochskaliert; das Original kommt danach in voller Auflösung zurück.
    static let maxPixels = 400_000
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

    /// Prompt mit Anweisung; doppelt wird sie nicht vorangestellt.
    static func prompt(_ text: String) -> String {
        text.hasPrefix(instruction) ? text : "\(instruction) \(text)".trimmingCharacters(in: .whitespaces)
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

    /// Original zurücklegen: im Inneren voll, zu den erweiterten Seiten hin über `blend` Pixel
    /// weich auslaufend (1 − ((F − d) / F)², wie ComfyUIs Feathering umgedreht).
    static func compositeOriginal(result: CGImage, original: CGImage, _ e: Edges) -> CGImage {
        let width = result.width, height = result.height
        let sx = Double(width) / Double(original.width + e.left + e.right)
        let sy = Double(height) / Double(original.height + e.top + e.bottom)
        let x0 = Double(e.left) * sx, x1 = x0 + Double(original.width) * sx
        let y0 = Double(e.top) * sy, y1 = y0 + Double(original.height) * sy   // von oben gezählt

        guard let base = rgba(result, width: width, height: height, draw: { ctx in
            ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
        }), let orig = rgba(result, width: width, height: height, draw: { ctx in
            ctx.draw(original, in: CGRect(x: x0, y: Double(height) - y1, width: x1 - x0, height: y1 - y0))
        }) else { return result }

        var out = base
        let feather = Double(blend)
        for row in 0..<height {
            let y = Double(row) + 0.5
            guard y >= y0, y < y1 else { continue }
            for col in 0..<width {
                let x = Double(col) + 0.5
                guard x >= x0, x < x1 else { continue }
                var d = Double.infinity
                if e.left > 0 { d = min(d, x - x0) }
                if e.right > 0 { d = min(d, x1 - x) }
                if e.top > 0 { d = min(d, y - y0) }
                if e.bottom > 0 { d = min(d, y1 - y) }
                let keep = d >= feather ? 1.0 : 1.0 - pow((feather - d) / feather, 2)
                let i = (row * width + col) * 4
                for c in 0..<3 {
                    out[i + c] = UInt8((Double(orig[i + c]) * keep + Double(base[i + c]) * (1 - keep)).rounded())
                }
                out[i + 3] = 255
            }
        }
        return makeImage(out, width: width, height: height) ?? result
    }

    private static func rgba(_ like: CGImage, width: Int, height: Int, draw: (CGContext) -> Void) -> [UInt8]? {
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

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
