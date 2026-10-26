import CoreGraphics
import Foundation
import ImageIO
import MLX
import UniformTypeIdentifiers

/// Startbild für LTX-Video: mittig auf das Seitenverhältnis des Videos zuschneiden und auf die Videogröße skalieren wie
/// Lightricks' `load_image_to_tensor_with_resize_and_crop`. Lightricks zeichnet danach 3 × 3 weich und komprimiert mit
/// H.264 (CRF 29), damit das Bild wie aus einem Video aussieht; beides gibt es hier nur für Prüfläufe (`preparation`).
/// Gemessen am Mac mini (26.10.2026, Welle und Lagerfeuer, 768 × 512, 49 Bilder, Seed 42): Mit der Kompression (HEIC
/// mit Qualität 0,43, auf dieselbe Abweichung abgestimmt wie CRF 29: je Bild ±0,6 dB, im Mittel 37,3 dB PSNR) stockte
/// die Bewegung im Zweierschritt wie ein 12-fps-Video (benachbarte Bildänderungen im Verhältnis 1,26 bis 1,79 statt
/// 1,04 bis 1,07, auch bei 1/8 Auflösung) und wurde kleiner. Weichzeichnen allein änderte die Bewegung uneinheitlich
/// (Welle +7 %, Feuer −9 %) und macht das erste Bild weicher. Vorgabe ist deshalb nur Zuschnitt und Skalierung.
/// Skripte: `scratchpad/ltxv/i2v_calib.py`, `heic_calib.swift`, `i2v_runs.sh`, `i2v_eval.py`.
enum VideoStartImage {
    /// none: Vorgabe; blur und compressed wie bei Lightricks, nur für Prüfläufe (`--video-prep`).
    enum Preparation: String { case none, blur, compressed }

    static let heicQuality = 0.43

    /// [1, H, W, 3] in [−1, 1] für `LTXImageEncoder.encode`.
    static func prepare(_ image: CGImage, width: Int, height: Int,
                        preparation: Preparation = .none) throws -> MLXArray {
        var pixels = rgb(ImageFiles.resized(cropped(image, aspect: Double(width) / Double(height)),
                                            width: width, height: height))
        if preparation != .none { pixels = blur(pixels, width: width, height: height) }
        if preparation == .compressed { pixels = try heicRoundTrip(pixels, width: width, height: height) }
        let floats = pixels.map { Float($0) / 127.5 - 1 }
        return MLXArray(floats, [1, height, width, 3])
    }

    /// Mittiger Ausschnitt mit dem Seitenverhältnis des Videos (wie Lightricks: ganze Pixel, abgerundet).
    static func cropped(_ image: CGImage, aspect: Double) -> CGImage {
        let w = image.width, h = image.height
        let rect: CGRect
        if Double(w) / Double(h) > aspect {
            let nw = Int(Double(h) * aspect)
            rect = CGRect(x: (w - nw) / 2, y: 0, width: nw, height: h)
        } else {
            let nh = Int(Double(w) / aspect)
            rect = CGRect(x: 0, y: (h - nh) / 2, width: w, height: nh)
        }
        return image.cropping(to: rect) ?? image
    }

    /// RGB-Bytes (ohne Alpha; durchsichtige Stellen werden schwarz) in sRGB.
    static func rgb(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0 ..< w * h {
            out[3 * i] = rgba[4 * i]
            out[3 * i + 1] = rgba[4 * i + 1]
            out[3 * i + 2] = rgba[4 * i + 2]
        }
        return out
    }

    /// `cv2.GaussianBlur(bild, (3, 3), 0)` auf 8 Bit: Kern [1, 2, 1] / 4 je Achse, Rand gespiegelt ohne Randpixel
    /// (reflect-101), gerundet.
    static func blur(_ pixels: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        func mirror(_ i: Int, _ n: Int) -> Int { i < 0 ? min(1, n - 1) : i >= n ? max(n - 2, 0) : i }
        var rows = [Int32](repeating: 0, count: pixels.count)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let l = mirror(x - 1, w), r = mirror(x + 1, w)
                for c in 0 ..< 3 {
                    rows[(y * w + x) * 3 + c] = Int32(pixels[(y * w + l) * 3 + c]) + 2 * Int32(pixels[(y * w + x) * 3 + c])
                        + Int32(pixels[(y * w + r) * 3 + c])
                }
            }
        }
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0 ..< h {
            let u = mirror(y - 1, h), d = mirror(y + 1, h)
            for x in 0 ..< w {
                for c in 0 ..< 3 {
                    let sum = rows[(u * w + x) * 3 + c] + 2 * rows[(y * w + x) * 3 + c] + rows[(d * w + x) * 3 + c]
                    out[(y * w + x) * 3 + c] = UInt8(clamping: (sum + 8) >> 4)
                }
            }
        }
        return out
    }

    /// Einmal als HEIC kodieren und wieder lesen.
    static func heicRoundTrip(_ pixels: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0 ..< w * h {
            rgba[4 * i] = pixels[3 * i]
            rgba[4 * i + 1] = pixels[3 * i + 1]
            rgba[4 * i + 2] = pixels[3 * i + 2]
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw failure }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw failure
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: heicQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw failure }
        let decoded = try ImageFiles.load(data as Data)
        guard decoded.width == w, decoded.height == h else { throw failure }
        return rgb(decoded)
    }

    private static var failure: APIError {
        APIError(500, t("Das Startbild ließ sich nicht aufbereiten (HEIC).", "Could not prepare the start image (HEIC)."))
    }
}
