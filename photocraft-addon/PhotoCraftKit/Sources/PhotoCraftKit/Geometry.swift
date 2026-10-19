import Foundation

/// Ganzzahliges Rechteck in Dokumentpixeln, `[x, y, w, h]` wie in PhotoCraft.
public struct Rect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var x1: Int { x + w }
    public var y1: Int { y + h }
    public var list: [Int] { [x, y, w, h] }
    public var description: String { "[\(x), \(y), \(w), \(h)]" }

    public init?(list: [Int]) {
        guard list.count == 4 else { return nil }
        self.init(list[0], list[1], list[2], list[3])
    }
}

/// Bildgeometrie zwischen PhotoCraft-Dokument und Modell (Referenz: bridge/imaging.py).
public enum Geometry {
    /// Die eingesetzten Modelle sind auf rund 1 Megapixel trainiert.
    public static let targetPixels = 1024 * 1024
    public static let minSide = 256
    public static let maxSide = 2048
    /// VAE (8×) mal Patch-Größe (2×).
    public static let multiple = 16

    /// Pythons `round`: bei exakt .5 zur geraden Zahl.
    static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// `r` um `margin` nach allen Seiten, auf die Arbeitsfläche begrenzt.
    public static func growRect(_ r: Rect, _ margin: Int, width: Int, height: Int) -> Rect {
        let x0 = max(0, r.x - margin), y0 = max(0, r.y - margin)
        let x1 = min(width, r.x1 + margin), y1 = min(height, r.y1 + margin)
        return Rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0))
    }

    /// Auswahl plus Umgebung (für „Füllen“).
    public static func contextRegion(_ sel: Rect, width: Int, height: Int, marginFrac: Double = 0.35,
                                     minMargin: Int = 32) -> Rect {
        let margin = max(minMargin, pyRound(Double(max(sel.w, sel.h)) * marginFrac))
        return growRect(sel, margin, width: width, height: height)
    }

    /// Arbeitsgröße fürs Modell: gleiche Proportion, rund `target` Pixel, Vielfache von 16.
    public static func workingSize(_ w: Int, _ h: Int, target: Int = targetPixels) -> (Int, Int) {
        precondition(w > 0 && h > 0, "ungültige Größe \(w)×\(h)")
        let s = (Double(target) / (Double(w) * Double(h))).squareRoot()
        var gw = Double(w) * s, gh = Double(h) * s
        if max(gw, gh) > Double(maxSide) {
            let f = Double(maxSide) / max(gw, gh)
            gw *= f
            gh *= f
        }
        if min(gw, gh) < Double(minSide) {
            let f = Double(minSide) / min(gw, gh)
            gw *= f
            gh *= f
        }
        func snap(_ v: Double) -> Int {
            min(maxSide, max(minSide, pyRound(v / Double(multiple)) * multiple))
        }
        return (snap(gw), snap(gh))
    }
}
