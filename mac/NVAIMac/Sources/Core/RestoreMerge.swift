import Foundation
import CoreGraphics
import Accelerate

/// Schonend restaurieren (seit 0.4.7): das Foto in voller Auflösung behalten und nur die Schäden aus dem
/// Ergebnis von FLUX.2 Klein einsetzen, dazu dessen großräumigen Ton (Kontrast, Verblassen). Dieselben Regeln
/// und Schwellen wie `restore_tools.merge_damage` unter Windows (`damage_mask`, `line_damage`); die Filter
/// rechnen wie scipy.ndimage (Gaußfilter mit gespiegeltem Rand, Rangfilter, Binärmorphologie).
///
/// Unter Windows gemessen (25.10.2026): Beim Baseballspieler von 1911 bekam eine von zwei gründlichen Varianten
/// ein anderes Gesicht, schonend blieb es das des Originals; Streifen, Handschrift, Staub und ein Papierstück
/// wurden ersetzt. Wasserränder, Craquelé und Korn bleiben dabei stehen, dafür ist gründlich da.
extension RestoreTools {
    // Schwellen wie restore_tools.py (Helligkeit L 0…100, Größen in Arbeitspixeln)
    static let spotLevel: Float = 8        // Kleinschäden: so viel heller/dunkler als die Umgebung
    static let bigLevel: Float = 25        // Großschäden (Riss, Papier, Lichteinfall)
    static let spotSize = 11               // größte Kleinschäden (Tophat)
    static let shiftTolerance = 7          // so weit darf das Gegenstück im Ergebnis daneben liegen
    static let lineLevel: Float = 6        // lange Schadenslinien (Kratzer, Knick)
    static let lineMin = 0.10              // ... mindestens so lang, als Anteil der längeren Bildseite
    static let lineRidge = 9               // größte Linienbreite (Tophat)
    static let toneSigma: Float = 24       // bis zu dieser Unschärfe kommen Ton und Kontrast von FLUX

    // MARK: Filter wie scipy.ndimage

    /// Index mit gespiegeltem Rand wie scipys Modus „reflect“ (d c b a | a b c d | d c b a).
    @inline(__always)
    static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * n
        var k = i % period
        if k < 0 { k += period }
        return k < n ? k : period - 1 - k
    }

    /// Jede Zeile mit `kernel` (ungerade Länge, symmetrisch) falten, Rand gespiegelt.
    static func convolveRows(_ v: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
        let radius = kernel.count / 2
        var out = [Float](repeating: 0, count: v.count)
        var padded = [Float](repeating: 0, count: width + 2 * radius)
        let index = (0..<(width + 2 * radius)).map { reflect($0 - radius, width) }
        v.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                padded.withUnsafeMutableBufferPointer { pad in
                    for row in 0..<height {
                        let base = row * width
                        for i in 0..<index.count { pad[i] = src[base + index[i]] }
                        vDSP_conv(pad.baseAddress!, 1, kernel, 1, dst.baseAddress! + base, 1,
                                  vDSP_Length(width), vDSP_Length(kernel.count))
                    }
                }
            }
        }
        return out
    }

    static func transposed(_ v: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: v.count)
        // vDSP_mtrans: C (M × N) = Aᵀ, A hat N Zeilen und M Spalten.
        vDSP_mtrans(v, 1, &out, 1, vDSP_Length(width), vDSP_Length(height))
        return out
    }

    /// Gaußfilter wie `ndi.gaussian_filter` (truncate 4, Rand „reflect“).
    static func gaussian(_ v: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = Int(4 * sigma + 0.5)
        var kernel = (-radius...radius).map { expf(-0.5 * Float($0 * $0) / (sigma * sigma)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        let rows = convolveRows(v, width: width, height: height, kernel: kernel)
        let cols = convolveRows(transposed(rows, width: width, height: height), width: height, height: width, kernel: kernel)
        return transposed(cols, width: height, height: width)
    }

    /// Minimum bzw. Maximum über ein Quadrat mit ungerader Kantenlänge `size` (`ndi.minimum_filter` /
    /// `maximum_filter`). Am Rand zählen nur die vorhandenen Pixel; gespiegelt ergäbe es dasselbe.
    static func rankFilter(_ v: [Float], width: Int, height: Int, size: Int, max useMax: Bool) -> [Float] {
        let r = size / 2
        var tmp = [Float](repeating: 0, count: v.count), out = tmp
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for row in 0..<height {
                    let base = row * width
                    for x in 0..<width {
                        let lo = Swift.max(0, x - r), hi = Swift.min(width - 1, x + r)
                        var m = src[base + lo]
                        if useMax { for i in (lo + 1)..<(hi + 1) where src[base + i] > m { m = src[base + i] } }
                        else { for i in (lo + 1)..<(hi + 1) where src[base + i] < m { m = src[base + i] } }
                        dst[base + x] = m
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let lo = Swift.max(0, y - r), hi = Swift.min(height - 1, y + r)
                    for x in 0..<width {
                        var m = src[lo * width + x]
                        if useMax { for j in (lo + 1)..<(hi + 1) where src[j * width + x] > m { m = src[j * width + x] } }
                        else { for j in (lo + 1)..<(hi + 1) where src[j * width + x] < m { m = src[j * width + x] } }
                        dst[y * width + x] = m
                    }
                }
            }
        }
        return out
    }

    /// Weißer (helle Kleinteile) bzw. schwarzer Tophat (dunkle) mit quadratischem Fenster.
    static func tophat(_ v: [Float], width: Int, height: Int, size: Int, white: Bool) -> [Float] {
        if white {
            let opened = rankFilter(rankFilter(v, width: width, height: height, size: size, max: false),
                                    width: width, height: height, size: size, max: true)
            return zip(v, opened).map { $0 - $1 }
        }
        let closed = rankFilter(rankFilter(v, width: width, height: height, size: size, max: true),
                                width: width, height: height, size: size, max: false)
        return zip(closed, v).map { $0 - $1 }
    }

    // MARK: Binärmasken

    /// `ndi.binary_dilation` mit Kreuz, `iterations`-mal (Manhattan-Abstand bis `iterations`).
    static func dilateCross(_ m: [Bool], width: Int, height: Int, iterations: Int) -> [Bool] {
        var cur = m
        for _ in 0..<iterations {
            var next = cur
            for y in 0..<height {
                for x in 0..<width where !cur[y * width + x] {
                    let i = y * width + x
                    if (x > 0 && cur[i - 1]) || (x + 1 < width && cur[i + 1])
                        || (y > 0 && cur[i - width]) || (y + 1 < height && cur[i + width]) { next[i] = true }
                }
            }
            cur = next
        }
        return cur
    }

    /// `ndi.binary_closing` mit 3×3-Quadrat und zwei Durchgängen: 5×5 dehnen, dann 5×5 abtragen; außerhalb des
    /// Bildes zählt beim Abtragen 0 (scipys border_value), der Rand von 2 px fällt deshalb weg.
    static func closeSquare(_ m: [Bool], width: Int, height: Int) -> [Bool] {
        let f = m.map { $0 ? Float(1) : 0 }
        let dilated = rankFilter(f, width: width, height: height, size: 5, max: true)
        let eroded = rankFilter(dilated, width: width, height: height, size: 5, max: false)
        var out = [Bool](repeating: false, count: m.count)
        guard width > 4, height > 4 else { return out }
        for y in 2..<(height - 2) { for x in 2..<(width - 2) { out[y * width + x] = eroded[y * width + x] > 0.5 } }
        return out
    }

    /// `ndi.binary_propagation(seeds, mask=mask)`: alles in `mask`, was über Nachbarn (Kreuz) an einem Keim hängt.
    static func propagate(_ seeds: [Bool], within mask: [Bool], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        for i in 0..<mask.count where seeds[i] && mask[i] { out[i] = true; stack.append(i) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (ok, j) in [(x > 0, i - 1), (x + 1 < width, i + 1), (y > 0, i - width), (y + 1 < height, i + width)]
            where ok && mask[j] && !out[j] {
                out[j] = true
                stack.append(j)
            }
        }
        return out
    }

    /// `ndi.binary_fill_holes`: Löcher füllen – was vom Hintergrund nicht über Nachbarn (Kreuz) mit dem
    /// Bildrand verbunden ist.
    static func fillHoles(_ m: [Bool], width: Int, height: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: m.count)
        var stack: [Int] = []
        func seed(_ i: Int) { if !m[i] && !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<width { seed(x); seed((height - 1) * width + x) }
        for y in 0..<height { seed(y * width); seed(y * width + width - 1) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (ok, j) in [(x > 0, i - 1), (x + 1 < width, i + 1), (y > 0, i - width), (y + 1 < height, i + width)]
            where ok && !m[j] && !outside[j] {
                outside[j] = true
                stack.append(j)
            }
        }
        return outside.map { !$0 }
    }

    // MARK: Schäden finden

    /// (weiche Maske 0…1, Kleinschäden, Großschäden) wie `restore_tools.damage_mask`; `go`/`gr` sind die
    /// Helligkeit von Foto und Ergebnis in Arbeitsgröße, mit σ 0,8 geglättet.
    static func damageMask(go: [Float], gr: [Float], width w: Int, height h: Int)
        -> (soft: [Float], small: [Bool], big: [Bool]) {
        let n = w * h
        var small = [Bool](repeating: false, count: n)
        for white in [true, false] {
            let to = tophat(go, width: w, height: h, size: spotSize, white: white)
            let tr = rankFilter(tophat(gr, width: w, height: h, size: spotSize, white: white),
                                width: w, height: h, size: shiftTolerance, max: true)
            for i in 0..<n where to[i] > spotLevel && tr[i] < 0.35 * to[i] { small[i] = true }
        }
        let d = zip(go, gr).map { $0 - $1 }
        let seeds = gaussian(d, width: w, height: h, sigma: 20).map { abs($0) > bigLevel }
        let blocked = dilateCross(zip(seeds, small).map { $0 || $1 }, width: w, height: h, iterations: 4)
        let keep = blocked.map { $0 ? Float(0) : 1 }
        let num = gaussian(zip(d, keep).map { $0 * $1 }, width: w, height: h, sigma: 40)
        let den = gaussian(keep, width: w, height: h, sigma: 40)
        let rest = (0..<n).map { d[$0] - num[$0] / (den[$0] + 1e-4) }
        let cand = gaussian(rest, width: w, height: h, sigma: 2).map { abs($0) > bigLevel * 0.5 }
        var big = fillHoles(propagate(zip(seeds, cand).map { $0 && $1 }, within: cand, width: w, height: h),
                            width: w, height: h)
        small = dilateCross(small, width: w, height: h, iterations: 2)
        big = dilateCross(big, width: w, height: h, iterations: 3)
        let softSmall = gaussian(small.map { $0 ? Float(1) : 0 }, width: w, height: h, sigma: 1.2)
        let softBig = gaussian(big.map { $0 ? Float(1) : 0 }, width: w, height: h, sigma: 3)
        let soft = (0..<n).map { Swift.max(Swift.min(1, softSmall[$0] * 1.6), Swift.min(1, softBig[$0] * 1.6)) }
        return (soft, small, big)
    }

    /// Lange dünne Schadenslinien wie `restore_tools.line_damage`: ein Grat im Foto, an derselben Stelle
    /// (± 2 px) keiner im Ergebnis, zusammenhängend (8 Nachbarn) mindestens `lineMin` der Bildseite lang und dünn.
    static func lineDamage(go: [Float], gr: [Float], width w: Int, height h: Int) -> [Bool] {
        let n = w * h
        let d = zip(go, gr).map { $0 - $1 }
        let blurred = gaussian(d, width: w, height: h, sigma: 6)
        var mask = [Bool](repeating: false, count: n)
        for white in [true, false] {
            let ro = tophat(go, width: w, height: h, size: lineRidge, white: white)
            let rr = rankFilter(tophat(gr, width: w, height: h, size: lineRidge, white: white),
                                width: w, height: h, size: 5, max: true)
            for i in 0..<n where ro[i] > lineLevel && rr[i] < 0.4 * ro[i] && abs(d[i] - blurred[i]) > lineLevel * 0.6 {
                mask[i] = true
            }
        }
        mask = closeSquare(mask, width: w, height: h)
        // Zusammenhängende Stücke (8 Nachbarn) behalten, die lang genug und dünn sind.
        var label = [Int32](repeating: 0, count: n)
        var out = [Bool](repeating: false, count: n)
        let minLength = lineMin * Double(Swift.max(w, h))
        var next: Int32 = 0
        var stack: [Int] = [], members: [Int] = []
        for start in 0..<n where mask[start] && label[start] == 0 {
            next += 1
            label[start] = next
            stack = [start]
            members = []
            var x0 = w, x1 = 0, y0 = h, y1 = 0
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                x0 = Swift.min(x0, x); x1 = Swift.max(x1, x); y0 = Swift.min(y0, y); y1 = Swift.max(y1, y)
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < w, dx != 0 || dy != 0 else { continue }
                        let j = yy * w + xx
                        if mask[j] && label[j] == 0 { label[j] = next; stack.append(j) }
                    }
                }
            }
            let length = Double(x1 - x0 + 1).hypot(Double(y1 - y0 + 1))
            if length >= minLength && Double(members.count) / length < 7 { for i in members { out[i] = true } }
        }
        return out
    }

    // MARK: Einsetzen

    /// Schonend restaurieren wie `restore_tools.merge_damage`: Feinzeichnung und Gesichter vom Foto in voller
    /// Auflösung, die Schäden und der großräumige Ton aus `restored`. `restored` muss vorher ausgerichtet sein
    /// (`align`); Masken und Ton entstehen in dessen Größe (Arbeitsgröße), zusammengesetzt wird in der des Fotos.
    static func mergeDamage(_ restored: CGImage, onto original: CGImage) -> (CGImage, JSONValue) {
        let w = restored.width, h = restored.height, n = w * h
        let rPx = rgba(restored, width: w, height: h)
        let oPx = rgba(original, width: w, height: h)
        let go = gaussian(lab(oPx, count: n).l, width: w, height: h, sigma: 0.8)
        let gr = gaussian(lab(rPx, count: n).l, width: w, height: h, sigma: 0.8)
        let mask = damageMask(go: go, gr: gr, width: w, height: h)
        let lines = dilateCross(lineDamage(go: go, gr: gr, width: w, height: h), width: w, height: h, iterations: 2)
        let softLines = gaussian(lines.map { $0 ? Float(1) : 0 }, width: w, height: h, sigma: 1.2)
        let soft = (0..<n).map { Swift.max(mask.soft[$0], Swift.min(1, softLines[$0] * 1.6)) }
        let damaged = (0..<n).map { mask.small[$0] || mask.big[$0] || lines[$0] }
        let keep = dilateCross(damaged, width: w, height: h, iterations: 2).map { $0 ? Float(0) : 1 }
        let weight = gaussian(keep, width: w, height: h, sigma: toneSigma)
        // Ton je Kanal: weichgezeichneter Unterschied Ergebnis − Foto außerhalb der Schäden (normierte Faltung).
        let tone: [[Float]] = (0..<3).map { c in
            let diff = (0..<n).map { (Float(rPx[$0 * 4 + c]) - Float(oPx[$0 * 4 + c])) * keep[$0] }
            let blurred = gaussian(diff, width: w, height: h, sigma: toneSigma)
            return (0..<n).map { blurred[$0] / (weight[$0] + 1e-4) }
        }

        // In voller Größe zusammensetzen; Ton und Maske bilinear aus der Arbeitsgröße.
        let fw = original.width, fh = original.height
        let full = rgba(original, width: fw, height: fh)
        let up = rgba(restored, width: fw, height: fh)
        var out = [UInt8](repeating: 255, count: fw * fh * 4)
        let sx = Double(w) / Double(fw), sy = Double(h) / Double(fh)
        let xs: [(Int, Int, Float)] = (0..<fw).map { x in
            let p = Swift.min(Swift.max((Double(x) + 0.5) * sx - 0.5, 0), Double(w - 1))
            let x0 = Int(p)
            return (x0, Swift.min(x0 + 1, w - 1), Float(p - Double(x0)))
        }
        var toneSum = 0.0
        soft.withUnsafeBufferPointer { m in
            for y in 0..<fh {
                let p = Swift.min(Swift.max((Double(y) + 0.5) * sy - 0.5, 0), Double(h - 1))
                let y0 = Int(p), y1 = Swift.min(y0 + 1, h - 1), fy = Float(p - Double(y0))
                for x in 0..<fw {
                    let (x0, x1, fx) = xs[x]
                    let a = y0 * w + x0, b = y0 * w + x1, c = y1 * w + x0, d = y1 * w + x1
                    func sample(_ v: UnsafeBufferPointer<Float>) -> Float {
                        let top = v[a] + (v[b] - v[a]) * fx, bottom = v[c] + (v[d] - v[c]) * fx
                        return top + (bottom - top) * fy
                    }
                    let mk = sample(m)
                    let o = (y * fw + x) * 4
                    for ch in 0..<3 {
                        let shift = tone[ch].withUnsafeBufferPointer { sample($0) }
                        toneSum += Double(abs(shift))
                        let base = Float(full[o + ch]) + shift
                        let v = base + mk * (Float(up[o + ch]) - base)
                        out[o + ch] = UInt8(Swift.max(0, Swift.min(255, v + 0.5)))
                    }
                }
            }
        }
        func percent(_ count: Int) -> JSONValue { .double((Double(count) / Double(n) * 10000).rounded() / 100) }
        let info: JSONValue = .object([
            "size": .array([.int(fw), .int(fh)]),
            "damage_percent": percent(soft.filter { $0 > 0.5 }.count),
            "small_percent": percent(mask.small.filter { $0 }.count),
            "big_percent": percent(mask.big.filter { $0 }.count),
            "lines_percent": percent(lines.filter { $0 }.count),
            "tone_shift": .double((toneSum / Double(fw * fh * 3) * 100).rounded() / 100),
        ])
        return (Outpaint.makeImage(out, width: fw, height: fh) ?? original, info)
    }
}

private extension Double {
    func hypot(_ other: Double) -> Double { (self * self + other * other).squareRoot() }
}
