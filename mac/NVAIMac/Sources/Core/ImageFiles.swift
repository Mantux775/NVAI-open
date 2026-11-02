import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Bilder laden, skalieren und als PNG schreiben – ohne AppKit, damit es auch im Server läuft.
enum ImageFiles {
    enum Failure: LocalizedError {
        case unreadable(String)
        case unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable(let what): return t("Bild nicht lesbar: \(what)", "Image not readable: \(what)")
            case .unwritable: return t("PNG ließ sich nicht schreiben.", "Could not write PNG.")
            }
        }
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = upright(source) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        return image
    }

    static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = upright(source) else {
            throw Failure.unreadable(t("Daten", "data"))
        }
        return image
    }

    /// EXIF-Orientierung des ersten Bildes, 1 = aufrecht, 5–8 = um 90° gedreht.
    private static func orientation(_ props: [CFString: Any]?) -> Int {
        (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Das Bild aufrecht: Handyfotos tragen die Drehung oft nur als EXIF-Angabe. Ohne sie gingen Restaurieren,
    /// Bild-zu-Bild, Referenzen und Startbild quer los, während die Vorschau das Foto richtig herum zeigte.
    private static func upright(_ source: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard orientation(props) != 1, let w = props?[kCGImagePropertyPixelWidth] as? Int,
              let h = props?[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unwritable }
        return data as Data
    }

    /// Auf genau diese Größe bringen (gestreckt, nicht beschnitten). Die PhotoCraft-App lädt
    /// Ausschnitt und Maske schon in der Arbeitsgröße hoch; das Ergebnis muss dazu passen.
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        if image.width == width && image.height == height { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Verkleinertes Vorschaubild (längste Seite `maxSide`).
    static func thumbnail(_ url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Breite und Höhe aus dem Dateikopf, ohne das Bild zu dekodieren (für Anzeigen im Formular).
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (5...8).contains(orientation(props)) ? (h, w) : (w, h)  // aufrechte Maße wie beim Laden
    }
}
