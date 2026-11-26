import Foundation

/// Geschätzte Rechenzeit eines Auftrags (seit Mac 1.0, wie server/nvai/estimate.py unter Windows; Konzept „NVAI im
/// Fluss“: „Ehrliche Zeit: vorher die Schätzung, währenddessen Phase und Restzeit“).
///
/// Zuerst aus eigenen Läufen auf diesem Mac: Median je Einheit aus den Angaben der Ergebnisse (`duration_s`, `gen_s`,
/// `seconds`), nur vergleichbare Läufe desselben Modells und Wegs, ab zwei Läufen. Sonst aus Messungen am Mac mini M1
/// mit 8 GB (notizen/mac.md, Läufe bis 26.11.2026), umgerechnet mit der Geschwindigkeit dieses Chips laut
/// Hardware-Katalog. Ohne Messung keine Zahl. Getrennt davon, was nur jetzt anfällt: ein Modell laden, das nicht im
/// Speicher liegt (`cold.load`, aus `load_s` eigener Läufe). Einen Rechner, der erst startet, gibt es auf dem Mac nicht.
struct JobEstimate: Sendable, Equatable {
    /// Rechenzeit in Sekunden; nil = keine Zahl
    var seconds: Double?
    /// history (gemessen auf diesem Mac), estimate (Messung am M1, umgerechnet), rough (grob), unknown
    var source: String = "unknown"
    /// eigene Läufe in der Schätzung
    var runs: Int = 0
    /// Modell laden, nur wenn es jetzt anfällt (Sekunden)
    var load: Double?
    var modelID: String?
    /// Studio: Art des Auftrags der Szene
    var kind: String?
    /// Studio: die Szene lässt sich so noch nicht erzeugen
    var error: String?

    /// Rechenzeit samt Laden, wenn es anfällt
    var total: Double? { seconds.map { $0 + (load ?? 0) } }

    static let unknown = JobEstimate()

    /// Antwortform wie unter Windows: seconds, source, runs, cold, model_id (+ kind, error im Studio)
    var json: JSONValue {
        var o: [String: JSONValue] = [
            "seconds": seconds.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            "source": .string(source), "runs": .int(runs),
            "cold": .object(load.map { ["load": .double(($0 * 10).rounded() / 10)] } ?? [:]),
            "model_id": modelID.map(JSONValue.string) ?? .null,
        ]
        if let kind { o["kind"] = .string(kind) }
        if let error { o["error"] = .string(error) }
        return .object(o)
    }
}

/// Ein eigener Lauf: Modell, Weg, Einheiten (siehe `Estimate.Reference`), Rechenzeit, Ladezeit
fileprivate struct EstimateSample: Sendable {
    let model: String
    let way: String
    let units: Double
    let seconds: Double
    let load: Double?
}

enum Estimate {
    // MARK: Messungen am Mac mini M1 (8 GB)

    /// Sekunden auf dem M1 = fest + je Einheit · Einheiten (bei Bildern je MP, mal Schritte durch `steps`). Einheiten
    /// je Art: Bilder MP, Video Mio. Bildpunkte (Breite × Höhe × Bilder), Ton Sekunden, Stimme Zeichen.
    struct Reference: Sendable {
        let fixed: Double
        let perUnit: Double
        let steps: Int
    }

    /// Je Modell und Weg; gemessen am Mac mini M1 mit 8 GB (Ergebnisse der Ablage, Stand 26.11.2026):
    /// FLUX.2 Klein 4B, 4 Schritte: Text zu Bild 22 Läufe 0,07–1,04 MP (512² 36–38 s, 1024 × 576 65 s, 768 × 1024 85 s,
    /// 1184 × 880 121 s), mit einer Referenz 14 Läufe (1024 × 576 150 s, 768 × 1024 204 s), Füllen 512² 37 s und
    /// 1024² 119 s; Z-Image Turbo 8 Schritte 512² 99 s, 768 × 432 126 s, 832 × 1216 399 s; LTX-Video 2B 9 Läufe
    /// (512 × 320 × 25 23 s, 800 × 448 × 97 168–174 s, 1152 × 640 × 49 179–181 s, jeweils mit Laden); Stable Audio 3
    /// 3–12,5 s Ton in 3,1–6,2 s; Qwen3-TTS 16–74 Zeichen in 1,3–6,6 s; Core ML SD 1.5 512², 25 Schritte 16,9 s.
    static let references: [String: Reference] = [
        "flux2-klein-4b|txt2img": Reference(fixed: 12, perUnit: 100, steps: 4),
        "flux2-klein-4b|references": Reference(fixed: 0, perUnit: 255, steps: 4),
        "flux2-klein-4b|inpaint": Reference(fixed: 10, perUnit: 104, steps: 4),
        "flux2-klein-4b|outpaint": Reference(fixed: 10, perUnit: 104, steps: 4),
        "z-image-turbo-q4|txt2img": Reference(fixed: 0, perUnit: 385, steps: 8),
        "coreml-sd15|txt2img": Reference(fixed: 0, perUnit: 64.5, steps: 25),
        "ltxv-2b-0.9.8-distilled|t2v": Reference(fixed: 3.5, perUnit: 4.85, steps: 0),
        "ltxv-2b-0.9.8-distilled|i2v": Reference(fixed: 3.5, perUnit: 4.85, steps: 0),
        "stable-audio-3-medium-mlx8|audio": Reference(fixed: 2.1, perUnit: 0.33, steps: 0),
        "qwen3-tts-mlx|speech": Reference(fixed: 0, perUnit: 0.08, steps: 0),
    ]

    /// Foto restaurieren auf dem M1 (FLUX.2 Klein 4B mit dem Foto als Referenz, Sekunden je MP der Arbeitsgröße):
    /// Schäden 69 s bei 0,31 MP und 180 s bei 0,79 MP, Einfärben 67 s bei 0,31 MP und 111 s bei 0,52 MP;
    /// „Automatisch“ fragt Qwen3.5 4B vorher (~20 s), Schärfen mit SeedVR2 ~20 s je Kachel von 384 px (25.10.2026).
    static let restoreRepairPerMP = 228.0
    static let restoreColorPerMP = 216.0
    static let restoreAutoSeconds = 20.0
    static let sharpenTileSeconds = 20.0

    /// Studio-Export (VideoToolbox, H.264) am M1: 1080p 144 Bilder in 0,9 s, 216 Bilder in 1,3 s (Sekunden je Bild und MP)
    static let exportPerFrameMP = 0.003

    // MARK: Einheiten und Wege

    private static func mp(_ w: Int, _ h: Int) -> Double { Double(w * h) / 1e6 }

    /// Weg eines Bildauftrags wie `EngineMode.name` (Erweitern eigens)
    static func imageWay(_ p: JSONValue) -> String {
        if let pad = p["outpaint"]?.arrayValue, pad.contains(where: { ($0.intValue ?? 0) > 0 }) { return "outpaint" }
        if p["mask_asset_id"]?.stringValue?.isEmpty == false { return "inpaint" }
        if p["image_asset_id"]?.stringValue?.isEmpty == false {
            return (p["denoise"]?.doubleValue ?? 0.5) >= 0.999 ? "references" : "img2img"
        }
        if !(p["reference_asset_ids"]?.arrayValue ?? []).isEmpty { return "references" }
        return "txt2img"
    }

    /// Weg eines erzeugten Bilds aus seinen Angaben (meta)
    private static func imageWay(meta: [String: JSONValue]) -> String {
        if meta["outpaint"] != nil { return "outpaint" }
        return meta["mode"]?.stringValue ?? "txt2img"
    }

    private static func steps(_ p: JSONValue, model: String) -> Int {
        if let s = p["steps"]?.intValue, s > 0 { return s }
        return Models.find(model)?.features["steps"] as? Int ?? 4
    }

    // MARK: Eigene Läufe

    private static let cache = EstimateCache()

    /// Läufe aus den Ergebnissen der Ablage, neueste zuerst, 10 s zwischengespeichert (die Oberfläche fragt oft)
    private static func samples() async -> [EstimateSample] {
        if let hit = cache.get() { return hit }
        var out: [EstimateSample] = []
        for a in await AssetStore.shared.list(limit: 3000) {
            let m = a.meta
            switch a.kind {
            case "image":
                guard m["restore"] == nil, let d = m["duration_s"]?.doubleValue, d > 0,
                      let w = m["width"]?.intValue, let h = m["height"]?.intValue else { continue }
                let s = Double(max(1, m["steps"]?.intValue ?? 4))
                out.append(EstimateSample(model: a.modelID, way: imageWay(meta: m), units: mp(w, h) * s, seconds: d,
                                          load: m["load_s"]?.doubleValue))
            case "video":
                guard a.modelID != "studio", let d = m["duration_s"]?.doubleValue, d > 0, let w = m["width"]?.intValue,
                      let h = m["height"]?.intValue, let f = m["frames"]?.intValue else { continue }
                out.append(EstimateSample(model: a.modelID, way: m["image_asset_id"] != nil ? "i2v" : "t2v",
                                          units: Double(w * h * f) / 1e6, seconds: d, load: nil))
            case "audio":
                if m["speech"]?.boolValue == true {
                    guard let g = m["gen_s"]?.doubleValue ?? m["duration_s"]?.doubleValue, g > 0,
                          let text = m["text"]?.stringValue, !text.isEmpty else { continue }
                    out.append(EstimateSample(model: a.modelID, way: "speech", units: Double(text.count), seconds: g,
                                              load: m["load_s"]?.doubleValue))
                } else {
                    guard let d = m["duration_s"]?.doubleValue, d > 0, let s = m["seconds"]?.doubleValue, s > 0 else { continue }
                    out.append(EstimateSample(model: a.modelID, way: "audio", units: s, seconds: d, load: m["load_s"]?.doubleValue))
                }
            default:
                continue
            }
        }
        cache.set(out)
        return out
    }

    /// Restaurieren aus eigenen Läufen: Sekunden je MP der Arbeitsgröße für Schäden und Farbe, mit Anzahl der Läufe
    private static func restoreRates() async -> (repair: Double?, color: Double?, runs: Int) {
        var repair: [Double] = [], color: [Double] = []
        for a in await AssetStore.shared.list(kind: "image", limit: 3000) where a.meta["restore"] != nil {
            let secs = a.meta["seconds"]?.objectValue ?? [:]
            if let s = secs["repair"]?.doubleValue, let w = a.meta["repair"]?["width"]?.intValue,
               let h = a.meta["repair"]?["height"]?.intValue, w * h > 0 { repair.append(s / mp(w, h)) }
            if let s = secs["colorize"]?.doubleValue, let w = a.meta["colorize"]?["width"]?.intValue,
               let h = a.meta["colorize"]?["height"]?.intValue, w * h > 0 { color.append(s / mp(w, h)) }
        }
        return (repair.count >= 2 ? median(Array(repair.prefix(12))) : nil,
                color.count >= 2 ? median(Array(color.prefix(12))) : nil, max(repair.count, color.count))
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Median Sekunden je Einheit aus bis zu zwölf vergleichbaren Läufen (zwischen halb und doppelt so groß)
    private static func history(_ all: [EstimateSample], model: String, way: String, units: Double) -> (perUnit: Double, runs: Int)? {
        guard units > 0 else { return nil }
        let close = all.filter { $0.model == model && $0.way == way && $0.units > 0 && (0.5...2.0).contains($0.units / units) }
            .prefix(12)
        guard close.count >= 2 else { return nil }
        return (median(close.map { $0.seconds / $0.units }), close.count)
    }

    /// Laden, das jetzt anfällt: Median der Ladezeiten dieses Modells aus eigenen Läufen, wenn es nicht im Speicher liegt
    private static func coldLoad(_ all: [EstimateSample], model: String, loaded: Bool) -> Double? {
        guard !loaded else { return nil }
        let loads = all.filter { $0.model == model }.compactMap(\.load).filter { $0 >= 0.1 }.prefix(12)
        return loads.isEmpty ? nil : median(Array(loads))
    }

    /// Sekunden des M1 auf diesen Mac umgerechnet; ohne Katalogwert unverändert und „grob“
    private static func scaled(_ m1Seconds: Double) -> (seconds: Double, source: String) {
        guard let sp = HardwareCatalog.speed else { return (m1Seconds, "rough") }
        return (m1Seconds / sp, "estimate")
    }

    private static func given(_ p: JSONValue) -> String? {
        p["model_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Schätzen

    /// Schätzung für einen Auftrag, wie ihn /api/generate/* bekäme. `kind` wie unter Windows (txt2img, txt2video,
    /// txt2audio, tts, restore, studio_export; img2img und img2video gehen auch).
    static func one(kind: String, params p: JSONValue) async -> JobEstimate {
        let all = await samples()
        switch kind {
        case "txt2img", "img2img", "image":
            let model = given(p) ?? Models.active.id
            let way = imageWay(p)
            var w = p["width"]?.intValue ?? 1024, h = p["height"]?.intValue ?? 1024
            if case .coreml(let m)? = Models.find(model) { w = m.resolution; h = m.resolution }
            // Erweitern: gerechnet wird auf Bild plus Rand
            if way == "outpaint", let id = p["image_asset_id"]?.stringValue, let size = pixelSize(id),
               let pad = p["outpaint"]?.arrayValue?.compactMap(\.intValue), pad.count == 4 {
                w = size.width + pad[0] + pad[2]
                h = size.height + pad[1] + pad[3]
            }
            let batch = Double(max(1, p["batch_size"]?.intValue ?? 1))
            let st = steps(p, model: model)
            let units = mp(w, h) * Double(st)
            var out = JobEstimate(modelID: model)
            if let hit = history(all, model: model, way: way, units: units) {
                out.seconds = hit.perUnit * units * batch
                out.source = "history"
                out.runs = hit.runs
            } else if let ref = references["\(model)|\(way)"] ?? (way == "img2img" ? references["\(model)|txt2img"] : nil) {
                // Bild zu Bild rechnet nur den Anteil „Stärke“ der Schritte (am M1 512 × 288 bei 0,5: 14 s statt 28 s)
                let share = way == "img2img" ? min(1, max(0.1, p["denoise"]?.doubleValue ?? 0.5)) : 1
                let m1 = (ref.fixed + ref.perUnit * mp(w, h) * Double(st) / Double(max(1, ref.steps)) * share) * batch
                let r = scaled(m1)
                out.seconds = r.seconds
                out.source = way == "img2img" || way == "outpaint" || (p["reference_asset_ids"]?.arrayValue?.count ?? 0) > 1
                    ? "rough" : r.source
            }
            out.load = coldLoad(all, model: model, loaded: await JobQueue.shared.recentlyUsed(model))
            return out
        case "txt2video", "img2video", "video":
            let model = given(p) ?? VideoCatalog.active.id
            let way = (p["image_asset_id"]?.stringValue?.isEmpty == false) ? "i2v" : "t2v"
            let units = Double((p["width"]?.intValue ?? 768) * (p["height"]?.intValue ?? 512) * (p["frames"]?.intValue ?? 97)) / 1e6
            var out = JobEstimate(modelID: model)
            if let hit = history(all, model: model, way: way, units: units) {
                out.seconds = hit.perUnit * units
                out.source = "history"
                out.runs = hit.runs
            } else if let ref = references["\(model)|\(way)"] {
                let r = scaled(ref.fixed + ref.perUnit * units)
                out.seconds = r.seconds
                out.source = r.source
            } else if model.hasPrefix("ltx-2.5"), let e = HardwareCatalog.estimate(model) {
                // Angabe des Pakets (768 × 512 × 121 mit Ton auf einem M5 Max), nicht selbst gemessen
                out.seconds = e.seconds * units / (768.0 * 512 * 121 / 1e6)
                out.source = "rough"
            }
            return out
        case "txt2audio", "audio":
            let secs = p["seconds"]?.doubleValue ?? 10
            var out = JobEstimate(modelID: AudioCatalog.id)
            if let hit = history(all, model: AudioCatalog.id, way: "audio", units: secs) {
                out.seconds = hit.perUnit * secs
                out.source = "history"
                out.runs = hit.runs
            } else if let ref = references["\(AudioCatalog.id)|audio"] {
                let r = scaled(ref.fixed + ref.perUnit * secs)
                out.seconds = r.seconds
                out.source = r.source
            }
            out.load = coldLoad(all, model: AudioCatalog.id, loaded: await JobQueue.shared.recentlyUsed(AudioCatalog.id))
            return out
        case "tts", "speech":
            let chars = Double(max(1, (p["text"]?.stringValue ?? "").count))
            var out = JobEstimate(modelID: SpeechCatalog.id)
            if let hit = history(all, model: SpeechCatalog.id, way: "speech", units: chars) {
                out.seconds = hit.perUnit * chars
                out.source = "history"
                out.runs = hit.runs
            } else if let ref = references["\(SpeechCatalog.id)|speech"] {
                let r = scaled(ref.fixed + ref.perUnit * chars)
                out.seconds = r.seconds
                out.source = r.source
            }
            out.load = coldLoad(all, model: SpeechCatalog.id, loaded: await JobQueue.shared.recentlyUsed(SpeechCatalog.id))
            return out
        case "restore":
            return await restore(p)
        case "studio_export":
            let frames = Double(p["frames"]?.intValue ?? 0), w = p["width"]?.intValue ?? 1920, h = p["height"]?.intValue ?? 1080
            guard frames > 0 else { return JobEstimate(modelID: "studio") }
            return JobEstimate(seconds: exportPerFrameMP * frames * mp(w, h), source: "rough", modelID: "studio")
        default:
            return JobEstimate(modelID: given(p))
        }
    }

    /// Foto restaurieren: je Variante Schäden und Farbe in ihrer Arbeitsgröße, dazu „Automatisch“ und Schärfen
    private static func restore(_ p: JSONValue) async -> JobEstimate {
        let repair = p["repair"]?.boolValue ?? true, colorize = p["colorize"]?.boolValue ?? false
        let sharpen = p["sharpen"]?.boolValue ?? false
        let batch = Double((repair || colorize) ? min(4, max(1, p["batch_size"]?.intValue ?? 1)) : 1)
        let model = given(p) ?? Models.expansionModel?.id
        guard let id = p["image_asset_id"]?.stringValue, let size = pixelSize(id) else { return JobEstimate(modelID: model) }
        let rates = await restoreRates()
        var m1 = 0.0
        var own = repair || colorize
        if repair {
            let work = RestoreJobRequest.workingSize(size.width, size.height,
                                                     megapixels: p["megapixels"]?.doubleValue ?? RestoreJobRequest.repairMegapixels)
            m1 += (rates.repair ?? restoreRepairPerMP) * mp(work.width, work.height) * batch
            own = own && rates.repair != nil
            if (p["repair_mode"]?.stringValue ?? "auto") == "auto" && HelperModel.vision.installed { m1 += restoreAutoSeconds }
        }
        if colorize {
            let work = RestoreJobRequest.workingSize(size.width, size.height, megapixels: RestoreJobRequest.colorizeMegapixels)
            m1 += (rates.color ?? restoreColorPerMP) * mp(work.width, work.height) * batch
            own = own && rates.color != nil
        }
        var rough = false
        if sharpen {
            let scale = p["scale"]?.doubleValue ?? 2
            var w = Double(size.width) * scale, h = Double(size.height) * scale
            let limit = Double(HelperModel.sharpenMaxPixels)
            if w * h > limit {
                let k = (limit / (w * h)).squareRoot()
                w *= k
                h *= k
            }
            let tile = Double(SeedVR2Engine.tile)
            func tiles(_ side: Double) -> Double { side <= tile ? 1 : ((side - 64) / (tile - 64)).rounded(.up) }
            // gemessen mit Kacheln von 384 px; größere Kacheln nach Fläche hochgerechnet
            m1 += tiles(w) * tiles(h) * sharpenTileSeconds * (tile / 384) * (tile / 384) * batch
            rough = tile != 384
        }
        if own && !sharpen { return JobEstimate(seconds: m1, source: "history", runs: rates.runs, modelID: model) }
        let r = scaled(m1)
        return JobEstimate(seconds: r.seconds, source: rough ? "rough" : r.source, modelID: model)
    }

    /// Mehrere Schätzungen auf einmal, jede so, als liefe sie jetzt allein (höchstens 64)
    static func many(_ items: [JSONValue]) async -> [JobEstimate] {
        var out: [JobEstimate] = []
        for item in items.prefix(64) {
            out.append(await one(kind: item["kind"]?.stringValue ?? "", params: item["params"] ?? .object([:])))
        }
        return out
    }

    private static func pixelSize(_ assetID: String) -> (width: Int, height: Int)? {
        guard let r = AssetSnapshot.shared.get(assetID) else { return nil }
        return ImageFiles.pixelSize(AssetStore.shared.fileURL(r.filename))
    }
}

/// Zwischenspeicher der eigenen Läufe (10 s), threadsicher
private final class EstimateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date.distantPast
    private var list: [EstimateSample] = []

    fileprivate func get() -> [EstimateSample]? {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(at) < 10 ? list : nil
    }

    fileprivate func set(_ value: [EstimateSample]) {
        lock.lock()
        at = Date()
        list = value
        lock.unlock()
    }
}
