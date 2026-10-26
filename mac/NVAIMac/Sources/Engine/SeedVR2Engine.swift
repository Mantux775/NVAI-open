import Foundation
import CoreGraphics
import MLX
import SeedVR2MLX

/// Schärfen und Vergrößern beim Restaurieren (seit 0.4.7): SeedVR2 3B (ByteDance, Apache-2.0) in 8 Bit über MLX,
/// die kleine Fassung des Modells, das unter Windows schärft (7B). SeedVR2 ändert die Größe nicht: Das Foto wird
/// erst auf die Zielgröße gebracht (Core Graphics, hohe Qualität), dann verfeinert SeedVR2 es in einem
/// Diffusionsschritt. Gerechnet wird in Kacheln mit überblendeten Rändern; die Farbe jeder Kachel wird danach an
/// ihre Vorlage angeglichen (LAB wie mflux), sonst entstünden Farbsprünge zwischen den Kacheln.
///
/// Real-ESRGAN (Core ML, 30 MB) war schneller, machte alte Fotos aber wachsartig: Korn und Hautstruktur
/// verschwanden (Vergleich am Herrn von 1910 in voller Auflösung, 25.10.2026).
actor SeedVR2Engine {
    static let shared = SeedVR2Engine()

    /// Kachelkante und Überlappung in Pixeln des Zielbildes (Vielfache von 16).
    static var tile: Int { SystemInfo.memoryGB <= 8 ? 384 : SystemInfo.memoryGB <= 16 ? 512 : 768 }
    static let overlap = 64

    private var upscaler: SeedVR2Upscaler?

    var isLoaded: Bool { upscaler != nil }

    func load(_ directory: URL) async throws {
        if upscaler != nil { return }
        upscaler = try await Task.detached(priority: .userInitiated) { try SeedVR2Upscaler(directory: directory) }.value
    }

    func unload() {
        upscaler = nil
        Memory.clearCache()
    }

    /// Kachelanfänge entlang einer Achse (die letzte Kachel endet am Rand).
    static func starts(_ length: Int, tile: Int) -> [Int] {
        guard length > tile else { return [0] }
        var out: [Int] = []
        var s = 0
        while true {
            let clamped = min(s, length - tile)
            if out.last != clamped { out.append(clamped) }
            if clamped + tile >= length { break }
            s += tile - overlap
        }
        return out
    }

    /// `image` auf `width` × `height` bringen und verfeinern; `progress(fertig, alle)` je Kachel.
    func upscale(_ image: CGImage, width: Int, height: Int, seed: UInt64,
                 progress: @Sendable (Int, Int) -> Void) throws -> CGImage {
        guard let upscaler else { throw APIError(500, t("SeedVR2 ist nicht geladen.", "SeedVR2 is not loaded.")) }
        let w = width, h = height
        let target = RestoreTools.rgba(image, width: w, height: h)
        let side = Self.tile
        let tw = min(side, w), th = min(side, h)
        let xs = Self.starts(w, tile: tw), ys = Self.starts(h, tile: th)
        // Auf Vielfache von 16 aufgefüllt (Randpixel wiederholt); abgeschnitten wird danach.
        let pw = (tw + 15) / 16 * 16, ph = (th + 15) / 16 * 16
        var acc = [Float](repeating: 0, count: w * h * 3)
        var weight = [Float](repeating: 0, count: w * h)
        var input = [Float](repeating: 0, count: 3 * pw * ph)
        let total = xs.count * ys.count
        var done = 0
        for y0 in ys {
            for x0 in xs {
                try Task.checkCancellation()
                for row in 0..<ph {
                    let yy = min(y0 + row, h - 1)
                    for col in 0..<pw {
                        let o = (yy * w + min(x0 + col, w - 1)) * 4
                        let q = row * pw + col
                        input[q] = Float(target[o]) / 127.5 - 1
                        input[pw * ph + q] = Float(target[o + 1]) / 127.5 - 1
                        input[2 * pw * ph + q] = Float(target[o + 2]) / 127.5 - 1
                    }
                }
                let x = MLXArray(input, [1, 3, ph, pw])
                var out = upscaler.upscale(processedImage: x, seed: seed)
                if out.ndim == 5 { out = out[0..., 0..., 0] }
                out = SeedVR2ColorCorrect.labTransfer(content: out[0..., 0..., 0 ..< ph, 0 ..< pw], style: x)
                let values = out.asType(.float32).asArray(Float.self)
                Memory.clearCache()
                // Überblenden: an inneren Kanten steigt das Gewicht über `overlap` Pixel linear an.
                for row in 0..<th {
                    let gy = y0 + row
                    var wy: Float = 1
                    if y0 > 0 { wy = min(wy, (Float(row) + 0.5) / Float(Self.overlap)) }
                    if y0 + th < h { wy = min(wy, (Float(th - row) - 0.5) / Float(Self.overlap)) }
                    for col in 0..<tw {
                        var wx: Float = 1
                        if x0 > 0 { wx = min(wx, (Float(col) + 0.5) / Float(Self.overlap)) }
                        if x0 + tw < w { wx = min(wx, (Float(tw - col) - 0.5) / Float(Self.overlap)) }
                        let g = gy * w + x0 + col, k = max(1e-3, wx * wy), q = row * pw + col
                        acc[g * 3] += k * values[q]
                        acc[g * 3 + 1] += k * values[pw * ph + q]
                        acc[g * 3 + 2] += k * values[2 * pw * ph + q]
                        weight[g] += k
                    }
                }
                done += 1
                progress(done, total)
            }
        }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let k = max(weight[i], 1e-6)
            for c in 0..<3 {
                let v = (acc[i * 3 + c] / k + 1) * 127.5
                px[i * 4 + c] = UInt8(max(0, min(255, v + 0.5)))
            }
        }
        guard let result = Outpaint.makeImage(px, width: w, height: h) else {
            throw APIError(500, t("Das geschärfte Bild ließ sich nicht anlegen.", "Could not create the sharpened image."))
        }
        return result
    }
}
