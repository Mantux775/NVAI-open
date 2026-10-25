import Foundation
import CoreGraphics

/// Fotos restaurieren (seit 0.4.6): das Ergebnis von FLUX.2 Klein am Foto ausrichten und von einem
/// eingefärbten Bild nur die Farbe übernehmen – dieselben Schritte wie `server/nvai/restore_tools.py` unter
/// Windows (`--align`, `--colorize`), mit denselben Formeln. Ohne AppKit, damit es im Server läuft.
///
/// Gemessen am 25.10.2026 auf dem M1 (8 GB): FLUX.2 Klein verschob ein restauriertes Foto um bis zu 2,7 px
/// und 0,4 % (Baseballspieler, 1040 × 752), ein eingefärbtes gar nicht. Ohne Ausrichten läge die Ebene in
/// PhotoCraft daneben und die Farbe neben den Kanten.
enum RestoreTools {
    /// Ein Kanal als Gleitkommazahlen, zeilenweise.
    struct Plane {
        var width: Int
        var height: Int
        var values: [Float]
    }

    struct Alignment {
        var scale = 1.0, dx = 0.0, dy = 0.0, score = 0.0
        var aligned = false

        var json: JSONValue {
            .object(["scale": .double((scale * 10000).rounded() / 10000), "dx": .double((dx * 10).rounded() / 10),
                     "dy": .double((dy * 10).rounded() / 10), "score": .double((score * 1000).rounded() / 1000),
                     "aligned": .bool(aligned)])
        }
    }

    // MARK: Pixel

    /// Graustufen in der gewünschten Größe (bilinear verkleinert wie Pillows `convert("L").resize`).
    static func gray(_ image: CGImage, width: Int, height: Int) -> Plane {
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Plane(width: width, height: height, values: buffer.map(Float.init))
    }

    /// RGBA8 (sRGB) in der gewünschten Größe.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        Outpaint.rgba(image, width: width, height: height) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        } ?? [UInt8](repeating: 0, count: width * height * 4)
    }

    // MARK: Ausrichten

    /// Normierte Kreuzkorrelation zwischen `t` und dem gleich großen Fenster von `r` bei (x, y).
    static func ncc(_ t: Plane, tMean: Float, tNorm: Float, _ r: Plane, x: Int, y: Int) -> Float {
        var sum: Float = 0, sumSq: Float = 0, cross: Float = 0
        let n = Float(t.width * t.height)
        t.values.withUnsafeBufferPointer { tv in
            r.values.withUnsafeBufferPointer { rv in
                for row in 0..<t.height {
                    let tBase = row * t.width
                    let rBase = (y + row) * r.width + x
                    for col in 0..<t.width {
                        let b = rv[rBase + col]
                        sum += b
                        sumSq += b * b
                        cross += (tv[tBase + col] - tMean) * b
                    }
                }
            }
        }
        let mean = sum / n
        let norm = max(0, sumSq - n * mean * mean).squareRoot()
        return cross / (tNorm * norm + 1e-6)
    }

    /// Wo das Original im Ergebnis liegt: Faktor und Versatz (in Pixeln des Ergebnisses in voller Größe,
    /// längste Seite `fullSide`) mit der besten Korrelation. Wie `outpaint_align.measure`: `result` ist das
    /// verkleinerte Suchbild, der Rand des Originals (je 10 %) zählt nicht; gesucht über `scales` und
    /// ± `span` Suchpixel um `around` (volle Pixel).
    static func measure(result: Plane, fullSide: Int, original: CGImage, scales: [Double], span: Int, step: Int,
                        around: (s: Double, x: Double, y: Double)? = nil) -> Alignment {
        let f = Double(fullSide) / Double(max(result.width, result.height))
        var best = Alignment(scale: 1, dx: 0, dy: 0, score: -2)
        let cx = around.map { $0.x / f } ?? 0, cy = around.map { $0.y / f } ?? 0
        for s in scales {
            let w = Int((Double(result.width) * s).rounded()), h = Int((Double(result.height) * s).rounded())
            let o = gray(original, width: w, height: h)
            let mx = w / 10, my = h / 10
            var t = Plane(width: w - 2 * mx, height: h - 2 * my, values: [])
            t.values.reserveCapacity(t.width * t.height)
            for row in my..<(h - my) { t.values.append(contentsOf: o.values[(row * w + mx)..<(row * w + w - mx)]) }
            let n = Float(t.values.count)
            let tMean = t.values.reduce(0, +) / n
            let tNorm = t.values.reduce(Float(0)) { $0 + ($1 - tMean) * ($1 - tMean) }.squareRoot()
            for dy in stride(from: Int(cy.rounded()) - span, through: Int(cy.rounded()) + span, by: step) {
                for dx in stride(from: Int(cx.rounded()) - span, through: Int(cx.rounded()) + span, by: step) {
                    let xs = dx + mx, ys = dy + my
                    guard xs >= 0, ys >= 0, xs + t.width <= result.width, ys + t.height <= result.height else { continue }
                    let v = Double(ncc(t, tMean: tMean, tNorm: tNorm, result, x: xs, y: ys))
                    if v > best.score { best = Alignment(scale: s, dx: Double(dx) * f, dy: Double(dy) * f, score: v) }
                }
            }
        }
        return best
    }

    /// Ergebnis so verschieben und skalieren, dass es sich mit dem Foto deckt (in der Größe des Ergebnisses).
    /// Unter `minScore` hat das Modell das Bild umgebaut statt nur bereinigt: dann bleibt es, wie es ist
    /// (wie `jobs.RESTORE_MIN_SCORE` unter Windows).
    static func align(_ result: CGImage, to original: CGImage, minScore: Double = 0.5) -> (CGImage, Alignment) {
        let width = result.width, height = result.height
        // Grob: längste Seite 384 px, Faktor 0,96–1,04, Versatz ± 6 % (FLUX.2 verschob gemessen bis 0,4 %, 3 px).
        let coarseSide = 384
        let fc = Double(max(width, height)) / Double(coarseSide)
        let small = gray(result, width: Int((Double(width) / fc).rounded()), height: Int((Double(height) / fc).rounded()))
        let span = Int((0.06 * Double(max(small.width, small.height))).rounded())
        // Schrittweite 2 wie outpaint_align; die Feinsuche fängt den Rest (± 4 px) auf.
        let fullSide = max(width, height)
        var best = measure(result: small, fullSide: fullSide, original: original,
                           scales: stride(from: 0.96, through: 1.0401, by: 0.01).map { $0 }, span: span, step: 2)
        // Fein: dreifache Auflösung, Faktor ± 0,006, Versatz ± 4 Suchpixel um den groben Treffer.
        let fineSide = min(1152, fullSide)
        let ff = Double(fullSide) / Double(fineSide)
        let large = gray(result, width: Int((Double(width) / ff).rounded()), height: Int((Double(height) / ff).rounded()))
        let fine = measure(result: large, fullSide: fullSide, original: original,
                           scales: stride(from: best.scale - 0.006, through: best.scale + 0.00601, by: 0.0015).map { $0 },
                           span: 4, step: 1, around: (best.scale, best.dx, best.dy))
        if fine.score >= best.score { best = fine }
        guard best.score >= minScore else {
            return (result, Alignment(scale: 1, dx: 0, dy: 0, score: best.score, aligned: false))
        }
        best.aligned = true
        // Ausgabe q zeigt Ergebnis p = s·q + (dx, dy). In CG (Ursprung unten links) liegt das Ergebnis
        // deshalb im Rechteck mit der linken oberen Ecke bei -(dx, dy)/s und der Größe (w, h)/s. Darunter das
        // unverschobene Ergebnis, damit dort, wo FLUX hineingezoomt hat, kein leerer Rand bleibt.
        let s = best.scale
        let pixels = Outpaint.rgba(result, width: width, height: height) { ctx in
            ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
            let w = Double(width) / s, h = Double(height) / s
            let left = -best.dx / s, top = -best.dy / s
            ctx.draw(result, in: CGRect(x: left, y: Double(height) - top - h, width: w, height: h))
        }
        guard let pixels, let image = Outpaint.makeImage(pixels, width: width, height: height) else { return (result, best) }
        return (image, best)
    }

    // MARK: Farbe (sRGB, D65)

    private static let m: [Float] = [0.4124564, 0.3575761, 0.1804375,
                                     0.2126729, 0.7151522, 0.0721750,
                                     0.0193339, 0.1191920, 0.9503041]
    private static let mInv: [Float] = [3.2404542, -1.5371385, -0.4985314,
                                        -0.9692660, 1.8760108, 0.0415560,
                                        0.0556434, -0.2040259, 1.0572252]
    private static let white: [Float] = [0.95047, 1.0, 1.08883]
    private static let d: Float = 6.0 / 29.0

    /// RGBA8 nach L, a, b (L 0…100).
    static func lab(_ px: [UInt8], count: Int) -> (l: [Float], a: [Float], b: [Float]) {
        var l = [Float](repeating: 0, count: count), a = l, b = l
        func lin(_ v: UInt8) -> Float {
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        func f(_ t: Float) -> Float { t > d * d * d ? cbrtf(t) : t / (3 * d * d) + 4.0 / 29.0 }
        for i in 0..<count {
            let r = lin(px[i * 4]), g = lin(px[i * 4 + 1]), bl = lin(px[i * 4 + 2])
            let fx = f((m[0] * r + m[1] * g + m[2] * bl) / white[0])
            let fy = f(m[3] * r + m[4] * g + m[5] * bl)
            let fz = f((m[6] * r + m[7] * g + m[8] * bl) / white[2])
            l[i] = 116 * fy - 16
            a[i] = 500 * (fx - fy)
            b[i] = 200 * (fy - fz)
        }
        return (l, a, b)
    }

    /// L, a, b nach RGBA8 (deckend).
    static func rgba(l: [Float], a: [Float], b: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: l.count * 4)
        func finv(_ t: Float) -> Float { t > d ? t * t * t : 3 * d * d * (t - 4.0 / 29.0) }
        func gamma(_ v: Float) -> UInt8 {
            let c = max(0, min(1, v))
            let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, s * 255 + 0.5)))
        }
        for i in 0..<l.count {
            let fy = (l[i] + 16) / 116
            let x = finv(fy + a[i] / 500) * white[0], y = finv(fy), z = finv(fy - b[i] / 200) * white[2]
            out[i * 4] = gamma(mInv[0] * x + mInv[1] * y + mInv[2] * z)
            out[i * 4 + 1] = gamma(mInv[3] * x + mInv[4] * y + mInv[5] * z)
            out[i * 4 + 2] = gamma(mInv[6] * x + mInv[7] * y + mInv[8] * z)
        }
        return out
    }

    /// Mittelwert über ein Quadrat mit Radius `r` (Integralbild; am Rand über die vorhandenen Pixel).
    static func boxMean(_ v: [Float], width: Int, height: Int, radius r: Int) -> [Float] {
        let w1 = width + 1
        var integral = [Double](repeating: 0, count: w1 * (height + 1))
        for y in 0..<height {
            var row: Double = 0
            for x in 0..<width {
                row += Double(v[y * width + x])
                integral[(y + 1) * w1 + x + 1] = integral[y * w1 + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: v.count)
        for y in 0..<height {
            let y0 = max(0, y - r), y1 = min(height, y + r + 1)
            for x in 0..<width {
                let x0 = max(0, x - r), x1 = min(width, x + r + 1)
                let sum = integral[y1 * w1 + x1] - integral[y0 * w1 + x1] - integral[y1 * w1 + x0] + integral[y0 * w1 + x0]
                out[y * width + x] = Float(sum / Double((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }

    /// Guided Filter (He et al.): `src` glätten, Kanten aber dort lassen, wo `guide` sie hat.
    static func guided(_ guide: [Float], _ src: [Float], width: Int, height: Int, radius: Int, eps: Float) -> [Float] {
        func box(_ v: [Float]) -> [Float] { boxMean(v, width: width, height: height, radius: radius) }
        let meanI = box(guide), meanP = box(src)
        let corrIP = box(zip(guide, src).map { $0 * $1 }), corrII = box(guide.map { $0 * $0 })
        var a = [Float](repeating: 0, count: guide.count), b = a
        for i in 0..<guide.count {
            let cov = corrIP[i] - meanI[i] * meanP[i]
            let variance = corrII[i] - meanI[i] * meanI[i]
            a[i] = cov / (variance + eps)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = box(a), meanB = box(b)
        return (0..<guide.count).map { meanA[$0] * guide[$0] + meanB[$0] }
    }

    /// Kanten ab rund 2 % Helligkeitsunterschied halten die Farbe auf (wie `GUIDE_EPS` unter Windows).
    static let guideEps: Float = 4e-4

    /// Farbe (a, b) von `color` auf die Helligkeit (L) von `luminance` legen, in dessen Größe. `color` muss
    /// vorher ausgerichtet sein. So bleiben Schärfe, Korn und Gesichter des Fotos; FLUX.2 veränderte beim
    /// Einfärben das Gesicht des Baseballspielers (es lächelte mehr), die Helligkeit bleibt aber die des Fotos.
    static func colorize(_ color: CGImage, onto luminance: CGImage) -> (CGImage, JSONValue) {
        let width = luminance.width, height = luminance.height, count = width * height
        let base = lab(rgba(luminance, width: width, height: height), count: count)
        let tint = lab(rgba(color, width: width, height: height), count: count)
        let factor = Double(max(width, height)) / Double(max(color.width, color.height))
        let radius = max(2, Int((2 * factor).rounded()))
        let guide = base.l.map { $0 / 100 }
        let a = guided(guide, tint.a, width: width, height: height, radius: radius, eps: guideEps)
        let b = guided(guide, tint.b, width: width, height: height, radius: radius, eps: guideEps)
        let out = rgba(l: base.l, a: a, b: b)
        let chroma = zip(a, b).reduce(Double(0)) { $0 + Double(($1.0 * $1.0 + $1.1 * $1.1).squareRoot()) } / Double(max(1, count))
        let info: JSONValue = .object(["size": .array([.int(width), .int(height)]),
                                       "color_size": .array([.int(color.width), .int(color.height)]),
                                       "factor": .double((factor * 100).rounded() / 100),
                                       "chroma": .double((chroma * 100).rounded() / 100)])
        return (Outpaint.makeImage(out, width: width, height: height) ?? luminance, info)
    }
}
