import Foundation
import IOKit

/// Hardware-Katalog (seit Mac 0.5.6; Nutzer 14.11.2026: „samele dafür ein katalog für unterschiedliche hardware und
/// platformen“, „nutze dieses hardware katalog auch bei model vorschlägen in Modelle und anderen berreichen“).
///
/// `hardware.json` ist dieselbe Datei wie unter Windows (`server/nvai/hardware.json`): 110 Grafikkarten und Chips mit
/// Speicher, Bandbreite und Rechendurchsatz, jeweils mit Quellen. Auf dem Mac zählen die Apple-Einträge (M1 bis M6,
/// je Ausbaustufe nach GPU-Kernen). Daraus: der erkannte Chip, seine Geschwindigkeit gegenüber dem Mac mini M1, auf dem
/// die Mac-Zeiten gemessen sind, und die typische Zeit je Modell. Die Geschwindigkeit ist eine grobe Schätzung aus der
/// GPU-Rechenleistung (FP32-TFLOPS, für M5 und neuer eine Untergrenze: Apple nennt für die neuen KI-Beschleuniger keine
/// Zahlen).
enum HardwareCatalog {
    struct Device: Decodable, Sendable {
        let id: String
        let name: String?
        let match: [String]?
        let exclude: [String]?
        let vendor: String?
        let arch: String?
        let memory_gb: [Double]?
        let fp16_tflops: Double?
        let gpu_cores: Int?
        let neural_accel: Bool?
        let uncertain: [String]?
    }

    private struct File: Decodable {
        let generated: String?
        let devices: [Device]
    }

    /// Mac mini M1 (8 GPU-Kerne, 8 GB): dort sind die Mac-Zeiten gemessen
    static let referenceID = "m1-8c"

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "hardware", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var devices: [Device] { file?.devices ?? [] }

    /// GPU-Kerne aus der IORegistry (AGXAccelerator „gpu-core-count“); nil, wenn macOS sie nicht nennt.
    static let gpuCores: Int? = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var cores: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                cores = value
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return cores
    }()

    /// Eintrag zu einem Chipnamen: einer der `match`-Teile kommt vor, kein `exclude`-Teil; bei mehreren Ausbaustufen
    /// die mit diesen GPU-Kernen, sonst die mit diesem Arbeitsspeicher, sonst die genaueste.
    static func match(_ name: String, cores: Int?, memoryGB: Int) -> Device? {
        let n = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var hits: [(Int, Device)] = []
        for d in devices where d.vendor == "apple" {
            let found = (d.match ?? []).filter { n.contains($0) }
            if !found.isEmpty, !(d.exclude ?? []).contains(where: { n.contains($0) }) {
                hits.append((found.map(\.count).max() ?? 0, d))
            }
        }
        if let cores, let exact = hits.filter({ $0.1.gpu_cores == cores }).max(by: { $0.0 < $1.0 }) { return exact.1 }
        let sized = hits.filter { h in (h.1.memory_gb ?? []).contains { abs($0 - Double(memoryGB)) < 1.5 } }
        return (sized.isEmpty ? hits : sized).max(by: { $0.0 < $1.0 })?.1
    }

    static let device: Device? = match(SystemInfo.chip, cores: gpuCores, memoryGB: SystemInfo.memoryGB)

    /// Wie viel schneller als der Mac mini M1; nil ohne Katalogwerte.
    static func speed(_ d: Device?) -> Double? {
        guard let mine = d?.fp16_tflops, let base = devices.first(where: { $0.id == referenceID })?.fp16_tflops, base > 0
        else { return nil }
        return min(30, max(0.2, mine / base))
    }

    static var speed: Double? { speed(device) }

    /// Typische Aufträge je Mac-Modell: Sekunden und auf welchem Chip gemessen (notizen/mac.md). task benennt die Einheit.
    struct Reference: Sendable {
        let seconds: Double
        let task: String
        let measuredOn: String
    }

    static let references: [String: Reference] = [
        "flux2-klein-4b": Reference(seconds: 37, task: "image_512", measuredOn: "m1-8c"),        // 512², 4 Schritte
        "z-image-turbo": Reference(seconds: 99, task: "image_512", measuredOn: "m1-8c"),         // 512², mit Laden
        "ltxv-2b-0.9.8-distilled": Reference(seconds: 174, task: "video_4s_512", measuredOn: "m1-8c"),  // 768 × 512 × 97
        // Angabe des Pakets ltx-video-swift-mlx (768 × 512 × 121 mit Ton auf einem M5 Max), nicht selbst gemessen
        "ltx-2.5-distilled": Reference(seconds: 93, task: "video_5s_512", measuredOn: "m5-max-40c"),
        "qwen3-tts": Reference(seconds: 2.7, task: "line", measuredOn: "m1-8c"),                  // 3 s Satz
        // 12 s Musik mit 8 Schritten, gemessen 14.11.2026 im Assistenten auf dem M1
        "stable-audio-3": Reference(seconds: 7.9, task: "music_12s", measuredOn: "m1-8c"),
    ]

    /// Zeit für einen typischen Auftrag dieses Modells auf diesem Mac (Referenz × Geschwindigkeit des Mess-Chips ÷
    /// Geschwindigkeit dieses Chips); nil ohne Messwert.
    static func estimate(_ modelID: String) -> (seconds: Double, task: String)? {
        guard let ref = references.first(where: { modelID.hasPrefix($0.key) })?.value,
              let here = speed,
              let there = speed(devices.first(where: { $0.id == ref.measuredOn })) else { return nil }
        return (ref.seconds * there / here, ref.task)
    }

    /// Kurz und rund: „≈ 40 s“, „≈ 12 min“, „≈ 1 h 20 min“
    static func duration(_ s: Double) -> String {
        if s < 10 { return "≈ \(max(1, Int(s.rounded()))) s" }
        if s < 90 { return "≈ \(Int((s / 5).rounded()) * 5) s" }
        let m = Int((s / 60).rounded())
        return m < 90 ? "≈ \(m) min" : "≈ \(m / 60) h \(m % 60) min"
    }

    static func taskLabel(_ task: String) -> String {
        switch task {
        case "image_512": return t("je Bild (512²)", "per image (512²)")
        case "video_4s_512": return t("je 4-s-Clip (768 × 512)", "per 4 s clip (768 × 512)")
        case "video_5s_512": return t("je 5-s-Clip (768 × 512)", "per 5 s clip (768 × 512)")
        case "line": return t("je Satz", "per line")
        case "music_12s": return t("je 12 s Musik", "per 12 s of music")
        default: return ""
        }
    }
}
