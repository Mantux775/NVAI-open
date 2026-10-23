import Foundation
import CoreGraphics

/// Erweitern auf dem Mac per Maske (FLUX.2 Klein kann Inpainting).
///
/// Der Referenzweg wie unter Windows (Bild auf grauem Rand, FLUX führt die Szene weiter) taugt mit
/// FLUX.2 Klein 4B nicht: Gemessen am M1 ließ es den grauen Rand rundum und bei breitem Format
/// (Achse für Achse) einfach stehen, und es verschiebt das Bild. Per Maske füllte es rundum in einem
/// Durchgang (1488 × 704 in 120 s), ohne das Bild zu verschieben; danach kommt das Original zurück.
extension Outpaint {
    /// Weicher Übergang der Maske ins Original (Pixel). Mit 48 blieb am Himmel ein sichtbarer Farbsprung.
    static let maskFeather = 96

    /// Maske im Format Bild + Rand: weiß = neu rechnen. Ins Original hinein läuft sie über
    /// `maskFeather` Pixel quadratisch aus, wie ComfyUIs ImagePadForOutpaint.
    static func mask(for image: CGImage, _ e: Edges) -> CGImage? {
        let w = image.width + e.left + e.right, h = image.height + e.top + e.bottom
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let f = Double(maskFeather)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let lx = Double(x) + 0.5, ly = Double(y) + 0.5
                var d = Double.infinity
                if e.left > 0 { d = min(d, lx) }
                if e.right > 0 { d = min(d, Double(image.width) - lx) }
                if e.top > 0 { d = min(d, ly) }
                if e.bottom > 0 { d = min(d, Double(image.height) - ly) }
                let v = d >= f ? 0 : pow((f - d) / f, 2)
                let i = ((y + e.top) * w + x + e.left) * 4
                let g = UInt8((v * 255).rounded())
                px[i] = g; px[i + 1] = g; px[i + 2] = g
            }
        }
        return makeImage(px, width: w, height: h)
    }

    /// Original zurücklegen (das Ergebnis hat das Format Bild + Rand, ohne Versatz), mit demselben
    /// weichen Übergang wie die Maske, umgekehrt.
    static func compositeOriginal(result: CGImage, original: CGImage, _ e: Edges) -> CGImage {
        let width = original.width + e.left + e.right, height = original.height + e.top + e.bottom
        let base = ImageFiles.resized(result, width: width, height: height)
        guard var out = rgba(base, width: width, height: height, draw: { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }), let orig = rgba(original, width: original.width, height: original.height, draw: { ctx in
            ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        }) else { return result }
        let f = Double(maskFeather)

        for y in 0..<original.height {
            for x in 0..<original.width {
                let lx = Double(x) + 0.5, ly = Double(y) + 0.5
                var d = Double.infinity
                if e.left > 0 { d = min(d, lx) }
                if e.right > 0 { d = min(d, Double(original.width) - lx) }
                if e.top > 0 { d = min(d, ly) }
                if e.bottom > 0 { d = min(d, Double(original.height) - ly) }
                let keep = d >= f ? 1 : 1 - pow((f - d) / f, 2)
                let o = (y * original.width + x) * 4, i = ((y + e.top) * width + x + e.left) * 4
                for c in 0..<3 {
                    out[i + c] = UInt8((Double(orig[o + c]) * keep + Double(out[i + c]) * (1 - keep)).rounded())
                }
                out[i + 3] = 255
            }
        }
        return makeImage(out, width: width, height: height) ?? result
    }
}
