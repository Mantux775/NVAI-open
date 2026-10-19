import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 8-Bit-Graustufenbild (Masken: 255 = neu erzeugen / ausgewählt).
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Halboffenes Rechteck `[x0, y0, x1, y1)` füllen (Golden-Daten).
    public mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, value: UInt8) {
        let xs = max(0, x0), xe = min(width, x1), ys = max(0, y0), ye = min(height, y1)
        guard xs < xe, ys < ye else { return }
        for y in ys..<ye {
            for x in xs..<xe { self[x, y] = value }
        }
    }
}

/// 8-Bit-RGBA mit gerader (nicht vormultiplizierter) Deckkraft.
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, color: [UInt8] = [0, 0, 0, 255]) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = color[0]
            pixels[i * 4 + 1] = color[1]
            pixels[i * 4 + 2] = color[2]
            pixels[i * 4 + 3] = color[3]
        }
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(pixels[i..<(i + 4)])
    }

    public mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, rgba: [UInt8]) {
        let xs = max(0, x0), xe = min(width, x1), ys = max(0, y0), ye = min(height, y1)
        guard xs < xe, ys < ye else { return }
        for y in ys..<ye {
            for x in xs..<xe {
                let i = (y * width + x) * 4
                pixels[i] = rgba[0]
                pixels[i + 1] = rgba[1]
                pixels[i + 2] = rgba[2]
                pixels[i + 3] = rgba[3]
            }
        }
    }

    public var alpha: GrayImage {
        GrayImage(width: width, height: height, pixels: stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] })
    }
}

public enum ImagingError: Error, LocalizedError {
    case unreadable(URL)
    case unwritable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return t("Bild nicht lesbar: \(url.path)", "image not readable: \(url.path)")
        case .unwritable(let url): return t("Bild nicht schreibbar: \(url.path)", "image not writable: \(url.path)")
        }
    }
}

/// Bildaufbereitung (Referenz: bridge/imaging.py). Analyse in Swift, Filter über Core Image.
public enum Imaging {
    /// Ohne Farbmanagement: Masken und Pixelwerte sollen nicht in Linearlicht umgerechnet werden.
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                             .cacheIntermediates: false])

    // MARK: Analyse

    /// Begrenzungsrechteck aller Pixel über `level`.
    public static func maskBBox(_ m: GrayImage, level: UInt8 = 8) -> Rect? {
        var x0 = m.width, y0 = m.height, x1 = -1, y1 = -1
        for y in 0..<m.height {
            for x in 0..<m.width where m[x, y] > level {
                x0 = min(x0, x)
                y0 = min(y0, y)
                x1 = max(x1, x)
                y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// Durchsichtige Stellen als Maske (weiß = neu erzeugen), `nil` bei deckendem Bild.
    public static func maskFromAlpha(_ img: RGBAImage, threshold: UInt8 = 250) -> GrayImage? {
        var m = GrayImage(width: img.width, height: img.height)
        var any = false
        for i in 0..<(img.width * img.height) where img.pixels[i * 4 + 3] < threshold {
            m.pixels[i] = 255
            any = true
        }
        return any ? m : nil
    }

    /// RGB fürs Modell: Transparenz mit der Mittelfarbe der deckenden Pixel (Alpha > 127) füllen.
    /// Mischung wie Pillows `paste(mask=)`, damit Kanten identisch werden.
    public static func flattenForModel(_ img: RGBAImage) -> RGBAImage {
        let n = img.width * img.height
        var sum = (0.0, 0.0, 0.0), count = 0.0
        var opaque = true
        for i in 0..<n {
            let a = img.pixels[i * 4 + 3]
            if a != 255 { opaque = false }
            if a > 127 {
                sum.0 += Double(img.pixels[i * 4])
                sum.1 += Double(img.pixels[i * 4 + 1])
                sum.2 += Double(img.pixels[i * 4 + 2])
                count += 1
            }
        }
        var out = img
        if opaque { return out }
        let mean: [Int] = count > 0 ? [Int(sum.0 / count), Int(sum.1 / count), Int(sum.2 / count)] : [128, 128, 128]
        for i in 0..<n {
            let a = Int(img.pixels[i * 4 + 3])
            for c in 0..<3 {
                out.pixels[i * 4 + c] = blend(mask: a, background: mean[c], foreground: Int(img.pixels[i * 4 + c]))
            }
            out.pixels[i * 4 + 3] = 255
        }
        return out
    }

    /// Pillows BLEND-Makro: (bg·(255−m) + fg·m) / 255 mit dessen Rundung.
    static func blend(mask m: Int, background bg: Int, foreground fg: Int) -> UInt8 {
        let a = bg * (255 - m) + fg * m
        let t = a + 128
        return UInt8(clamping: ((t >> 8) + t) >> 8)
    }

    // MARK: Core Image

    static func ciImage(_ m: GrayImage) -> CIImage {
        CIImage(bitmapData: Data(m.pixels), bytesPerRow: m.width,
                size: CGSize(width: m.width, height: m.height), format: .L8, colorSpace: nil)
    }

    static func ciImage(_ img: RGBAImage) -> CIImage {
        CIImage(bitmapData: Data(img.pixels), bytesPerRow: img.width * 4,
                size: CGSize(width: img.width, height: img.height), format: .RGBA8, colorSpace: nil)
    }

    static func renderGray(_ image: CIImage, width: Int, height: Int) -> GrayImage {
        var out = [UInt8](repeating: 0, count: width * height)
        context.render(image, toBitmap: &out, rowBytes: width,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: nil)
        return GrayImage(width: width, height: height, pixels: out)
    }

    static func renderRGBA(_ image: CIImage, width: Int, height: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &out, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: nil)
        return RGBAImage(width: width, height: height, pixels: out)
    }

    /// Auf Zielgröße skalieren; Ränder werden fortgesetzt statt ausgeblendet.
    static func scaled(_ image: CIImage, from src: (Int, Int), to dst: (Int, Int), lanczos: Bool) -> CIImage {
        let sx = Double(dst.0) / Double(src.0), sy = Double(dst.1) / Double(src.1)
        let clamped = image.clampedToExtent()
        let out: CIImage
        if lanczos {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = clamped
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            out = f.outputImage ?? clamped
        } else {
            out = clamped.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: dst.0, height: dst.1))
    }

    public static func resize(_ m: GrayImage, to size: (Int, Int)) -> GrayImage {
        if (m.width, m.height) == size { return m }
        return renderGray(scaled(ciImage(m), from: (m.width, m.height), to: size, lanczos: false),
                          width: size.0, height: size.1)
    }

    public static func resize(_ img: RGBAImage, to size: (Int, Int)) -> RGBAImage {
        if (img.width, img.height) == size { return img }
        return renderRGBA(scaled(ciImage(img), from: (img.width, img.height), to: size, lanczos: true),
                          width: size.0, height: size.1)
    }

    /// Maske auf Arbeitsgröße, um `grow` px erweitern (quadratisch), Rand weichzeichnen.
    public static func prepareModelMask(_ mask: GrayImage, size: (Int, Int), grow: Int, blur: Double) -> GrayImage {
        var image = scaled(ciImage(mask), from: (mask.width, mask.height), to: size, lanczos: false)
        let extent = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        if grow > 0 {
            let f = CIFilter.morphologyRectangleMaximum()
            f.inputImage = image.clampedToExtent()
            f.width = Float(2 * grow + 1)
            f.height = Float(2 * grow + 1)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        if blur > 0 {
            let f = CIFilter.gaussianBlur()
            f.inputImage = image.clampedToExtent()
            f.radius = Float(blur)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        return renderGray(image, width: size.0, height: size.1)
    }

    /// Maske als Alphakanal ins Bild legen (Maske bilinear auf Bildgröße).
    public static func bakeAlpha(_ img: RGBAImage, mask: GrayImage) -> RGBAImage {
        let m = resize(mask, to: (img.width, img.height))
        var out = img
        for i in 0..<(img.width * img.height) { out.pixels[i * 4 + 3] = m.pixels[i] }
        return out
    }

    /// Exakt auf `w`×`h` strecken (Füllen, Überarbeiten – hebt die Stauchung des Uploads auf).
    public static func fitExact(_ img: RGBAImage, width: Int, height: Int) -> RGBAImage {
        var out = resize(img, to: (width, height))
        for i in 0..<(width * height) { out.pixels[i * 4 + 3] = 255 }
        return out
    }

    /// Füllen und mittig beschneiden (Generieren) – wie Pillows `ImageOps.fit`.
    public static func fitCover(_ img: RGBAImage, width: Int, height: Int) -> RGBAImage {
        let live = (Double(img.width), Double(img.height))
        let liveRatio = live.0 / live.1, outRatio = Double(width) / Double(height)
        var crop = live
        if liveRatio > outRatio {
            crop = (outRatio * live.1, live.1)
        } else if liveRatio < outRatio {
            crop = (live.0, live.0 / outRatio)
        }
        let left = (live.0 - crop.0) * 0.5, top = (live.1 - crop.1) * 0.5
        // Core Image zählt y von unten.
        let rect = CGRect(x: left, y: live.1 - top - crop.1, width: crop.0, height: crop.1)
        let cropped = ciImage(img).cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = cropped.clampedToExtent()
        f.scale = Float(Double(height) / crop.1)
        f.aspectRatio = Float((Double(width) / crop.0) / (Double(height) / crop.1))
        let out = (f.outputImage ?? cropped).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var rgba = renderRGBA(out, width: width, height: height)
        for i in 0..<(width * height) { rgba.pixels[i * 4 + 3] = 255 }
        return rgba
    }

    // MARK: Dateien

    public static func readRGBA(_ url: URL) throws -> RGBAImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImagingError.unreadable(url) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ImagingError.unreadable(url) }
        // CGContext liefert vormultipliziert – zurückrechnen auf gerade Deckkraft.
        for i in 0..<(w * h) {
            let a = Int(px[i * 4 + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { px[i * 4 + c] = UInt8(min(255, (Int(px[i * 4 + c]) * 255 + a / 2) / a)) }
            }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }

    public static func readGray(_ url: URL) throws -> GrayImage {
        let rgba = try readRGBA(url)
        return GrayImage(width: rgba.width, height: rgba.height,
                         pixels: (0..<(rgba.width * rgba.height)).map { rgba.pixels[$0 * 4] })
    }

    public static func pngData(_ img: RGBAImage) throws -> Data {
        try encodePNG(width: img.width, height: img.height, bytesPerPixel: 4, pixels: img.pixels,
                      space: CGColorSpaceCreateDeviceRGB(), alpha: .last)
    }

    public static func pngData(_ m: GrayImage) throws -> Data {
        try encodePNG(width: m.width, height: m.height, bytesPerPixel: 1, pixels: m.pixels,
                      space: CGColorSpaceCreateDeviceGray(), alpha: .none)
    }

    public static func writePNG(_ img: RGBAImage, to url: URL) throws {
        try pngData(img).write(to: url)
    }

    public static func writePNG(_ m: GrayImage, to url: URL) throws {
        try pngData(m).write(to: url)
    }

    static func encodePNG(width: Int, height: Int, bytesPerPixel: Int, pixels: [UInt8], space: CGColorSpace,
                          alpha: CGImageAlphaInfo) throws -> Data {
        let url = URL(fileURLWithPath: "memory.png")
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel,
                               bytesPerRow: width * bytesPerPixel, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ImagingError.unwritable(url)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ImagingError.unwritable(url)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImagingError.unwritable(url) }
        return data as Data
    }
}
