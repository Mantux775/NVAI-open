import Foundation

/// Speicherplatz für neue Fälle (seit 0.5.11). Ein Fall ist ein Vielfaches seiner Quelle: Ein VDR-Export brauchte je
/// Stunde Aufnahme und Tonkanal rund 0,17 GB (Ton als 16-Bit-WAV, dazu Spektrogramme +35 %, AAC +19 %), dazu die Bilder.
/// Ein voller Datenträger legt den ganzen Mac lahm (macOS lagert Speicher dorthin aus); deshalb prüft der Auftrag vor dem
/// Start und während des Imports, dass genug frei bleibt, und bricht sonst sauber ab (der halbe Fall wird gelöscht).
final class ForensicDiskGuard: @unchecked Sendable {
    /// so viel bleibt für macOS frei
    static let reserve: Int64 = 3_000_000_000

    private let volume: URL
    private let lock = NSLock()
    private var lastCheck = Date.distantPast
    private var isLow = false

    init(_ volume: URL) { self.volume = volume }

    /// Platz auf dem Datenträger von `url`, samt dem, was macOS auf Anforderung freiräumt (etwa lokale Schnappschüsse)
    static func available(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey]) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v.volumeAvailableCapacity.map { Int64($0) }
    }

    /// Wird es knapp? Höchstens einmal je Sekunde nachgesehen (der Import fragt sehr oft); einmal knapp bleibt knapp.
    var low: Bool {
        lock.lock()
        defer { lock.unlock() }
        if isLow { return true }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= 1 else { return false }
        lastCheck = now
        if let free = Self.available(volume), free < Self.reserve { isLow = true }
        return isLow
    }

    var tripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isLow
    }

    static func message(_ url: URL) -> String {
        let free = available(url).map(gb) ?? "?"
        return t("Abgebrochen, bevor der Datenträger voll ist: Für die Fälle sind nur noch \(free) GB frei, \(gb(reserve)) GB bleiben für macOS. Bitte Platz schaffen und den Fall neu anlegen.",
                 "Cancelled before the drive runs full: only \(free) GB are left for the cases, \(gb(reserve)) GB stay free for macOS. Please free up space and create the case again.")
    }

    /// Geschätzte Größe eines Falls aus einem VDR-Export: Ton je Kanal mit 2 Byte je Probe, dazu Spektrogramme und AAC
    /// (zusammen +54 %, gemessen), die Bilder höchstens so groß wie der ganze Export.
    static func vdrEstimate(seconds: Int, rates: [Int], exportBytes: Int64) -> Int64 {
        let audio = Double(max(seconds, 0)) * Double(rates.reduce(0, +)) * 2
        return Int64(audio * 1.54) + exportBytes
    }

    /// „12,3“ bzw. „12.3“, in GB wie der Finder (10⁹ Byte)
    static func gb(_ bytes: Int64) -> String {
        let s = String(format: "%.1f", Double(bytes) / 1e9)
        return Lang.ui == .de ? s.replacingOccurrences(of: ".", with: ",") : s
    }
}

/// Vorschau vor „Neuer Fall“ aus einem VDR-Export, wie „Prüfen“ unter Windows (`VDR.inspect`, unter 5 s): Gerät, Zeitraum,
/// Blöcke und Lücken, Kanäle, Bildquellen und der geschätzte Platzbedarf.
struct VDRPreview: Sendable {
    var folder: URL
    var product: String
    var start: String
    var end: String
    var duration: Int
    var blocks: Int
    var gaps: Int
    var channels: [String]
    var rates: [Int]
    var images: Int
    var exportBytes: Int64
    var estimate: Int64
    var free: Int64?

    init(_ url: URL) throws {
        let s = try VDR.inspect(url).summary
        folder = url
        product = s["product"] as? String ?? "VDR"
        start = s["start"] as? String ?? ""
        end = s["end"] as? String ?? ""
        duration = s["duration"] as? Int ?? 0
        blocks = s["blocks"] as? Int ?? 0
        gaps = s["gap_count"] as? Int ?? 0
        let audio = s["audio"] as? [[String: Any]] ?? []
        channels = audio.map { c in
            [c["input"] as? String, c["position"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        rates = audio.map { $0["rate"] as? Int ?? 16_000 }
        if rates.isEmpty {   // ohne Konfiguration: je Ogg-Datei zwei Kanäle
            rates = Array(repeating: 16_000, count: 2 * ((s["audio_files"] as? [String])?.count ?? 0))
        }
        images = (s["images"] as? [Any])?.count ?? 0
        exportBytes = Int64(s["size_bytes"] as? Int ?? 0)
        estimate = ForensicDiskGuard.vdrEstimate(seconds: duration, rates: rates, exportBytes: exportBytes)
        free = ForensicDiskGuard.available(ForensicCases.directory)
    }

    /// Name wie unter Windows: „VDR <Beginn> UTC“
    var suggestedName: String { start.isEmpty ? product : "VDR \(start) UTC" }

    /// Passt der Fall samt Rückhalt für macOS auf den Datenträger der Fälle?
    var fits: Bool { free.map { $0 - ForensicDiskGuard.reserve >= estimate } ?? true }

    var json: [String: Any] {
        ["product": product, "start": start, "end": end, "duration": duration, "blocks": blocks, "gaps": gaps,
         "channels": channels, "images": images, "size_bytes": exportBytes, "estimate_bytes": estimate,
         "free_bytes": free.map { $0 as Any } ?? NSNull(), "fits": fits, "name": suggestedName]
    }
}
