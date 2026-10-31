import Foundation
import LTXV
import MLX

/// Video über den eigenen MLX-Port `Packages/ltxv-swift`: Text oder Startbild zu Video in acht Schritten ohne
/// Gewichtung, 24 Bilder je Sekunde, ohne Ton.
/// - **LTX-Video 2B 0.9.8 distilled** (seit 0.4.8): Transformer, VAE-Decoder und VAE-Encoder per Byte-Bereich aus
///   Lightricks' Einzeldatei (bf16).
/// - **LTX-Video 13B 0.9.8 distilled** (seit 0.5.0, für Macs ab 16 GB): derselbe Aufbau, 48 statt 28 Blöcke der Breite
///   4096; der Transformer kommt aus Lightricks' fp8-Datei (13,2 GB) und wird beim Laden in 4 Bit (16 GB) oder 8 Bit
///   (24 GB) umgewandelt. Gegen ComfyUIs Rechnung geprüft (zwei Blöcke, float32: relL2 2,6e-6; 8 Bit 7,3e-3 wie bf16,
///   4 Bit 2,3e-2). Den ganzen Lauf konnte NVAI-open auf dem 8-GB-Testgerät nicht rechnen: Speicherbedarf und Zeiten
///   sind geschätzt.
/// Alle teilen den T5-XXL-Text-Encoder in der 4-Bit-Fassung von mflux (2,7 GB; bitgleich mit LTX-Videos T5), seinen
/// Tokenizer (google-t5/t5-base) und die Positions-Tabelle in float32. Der Bild-Encoder (nur fürs Startbild) kommt roh
/// mit 1,39 GB und wird einmal auf 2D-Kerne in float16 umgewandelt (0,46 GB); der VAE ist bei 2B und 13B byte-gleich.
struct VideoModel: Identifiable, Hashable, Sendable {
    let id: String
    /// nil: Transformer in bf16 (2B); 4 oder 8: aus der fp8-Datei umgewandelt (13B).
    let bits: Int?
    let ltxFile: String
    /// Ab so viel Arbeitsspeicher; die Empfehlung gilt bis unter `minRAMGB` des nächstgrößeren Modells.
    let minRAMGB: Int
    /// Speicherspitze bei 768 × 512 × 97 (2B gemessen, 13B geschätzt: Gewichte plus das Doppelte der Aktivierungen
    /// des 2B).
    let needGB: Double
    /// Transformer-Tensoren im Download und auf der Platte (LTX-2: alle Dateien des Pakets).
    let ditDownloadBytes: Int64
    let ditDiskBytes: Int64
    /// LTX-2 aus `Packages/ltx-video-swift-mlx` (Rohwert von `LTXModel`: "distilled" = 2.3, "2.5-distilled");
    /// nil = LTX-Video 0.9.8 im eigenen Port.
    var ltx2: String? = nil

    static let ltxv2B = VideoModel(id: "ltxv-2b-0.9.8-distilled", bits: nil, ltxFile: "ltxv-2b-0.9.8-distilled.safetensors",
                                   minRAMGB: 8, needGB: 6.2, ditDownloadBytes: 3_846_800_000, ditDiskBytes: 3_846_800_000)
    static let ltxv13BQ4 = VideoModel(id: "ltxv-13b-0.9.8-distilled-q4", bits: 4,
                                      ltxFile: "ltxv-13b-0.9.8-distilled-fp8.safetensors", minRAMGB: 16, needGB: 10.5,
                                      ditDownloadBytes: 13_200_000_000, ditDiskBytes: 6_800_000_000)
    static let ltxv13BQ8 = VideoModel(id: "ltxv-13b-0.9.8-distilled-q8", bits: 8,
                                      ltxFile: "ltxv-13b-0.9.8-distilled-fp8.safetensors", minRAMGB: 24, needGB: 17,
                                      ditDownloadBytes: 13_200_000_000, ditDiskBytes: 13_300_000_000)
    /// LTX-2.3 distilled mit Ton, Transformer beim Laden in 4 Bit (Paket: ab 32 GB empfohlen; gemessen dort bei
    /// 1024 × 576 × 241 mit Ton 38,4 GB auf einem M3 Max, für 768 × 512 × 121 geschätzt ~28 GB). Download rund 46 GB.
    static let ltx23 = VideoModel(id: "ltx-2.3-distilled-int4", bits: 4, ltxFile: "ltx-2.3-22b-distilled.safetensors",
                                  minRAMGB: 32, needGB: 28, ditDownloadBytes: 46_000_000_000,
                                  ditDiskBytes: 46_000_000_000, ltx2: "distilled")
    /// LTX-2.5 distilled mit Ton (wie unter Windows), Transformer in 8 Bit (Paket: 70 GB in bf16, int4 schon beim
    /// Laden ~38 GB; 8 Bit geschätzt ~50 GB). Gesperrtes Repo, Download rund 70 GB.
    static let ltx25 = VideoModel(id: "ltx-2.5-distilled-q8", bits: 8,
                                  ltxFile: "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors",
                                  minRAMGB: 64, needGB: 50, ditDownloadBytes: 70_000_000_000,
                                  ditDiskBytes: 70_000_000_000, ltx2: "2.5-distilled")

    var isLTX2: Bool { ltx2 != nil }
    var is13B: Bool { bits != nil && !isLTX2 }
    /// LTX-2.5 liegt auf Hugging Face hinter einer Lizenzabfrage (Token nötig).
    var gated: Bool { ltx2 == "2.5-distilled" }
    var hasAudio: Bool { isLTX2 }
    /// LTX-2 verlangt Breite und Höhe in Vielfachen von 64, LTX-Video 0.9.8 von 32.
    var sizeStep: Int { isLTX2 ? 64 : 32 }
    var transformerConfig: LTXTransformerConfiguration { is13B ? .ltxv13B : LTXTransformerConfiguration() }
    /// Lightricks' `tone_map_compression_ratio` aus der Pipeline-Einstellung des 13B, vor dem Dekodieren.
    var toneMap: Float { is13B ? 0.6 : 0 }

    var directory: URL {
        isLTX2 ? LTX2Engine.directory : Settings.modelsDirectory.appendingPathComponent("\(VideoCatalog.ltxRepo)/\(id)")
    }
    var decoderFile: URL { directory.appendingPathComponent("vae-decoder.safetensors") }
    /// Der Bild-Encoder fürs Startbild, umgewandelt (2D-Kerne, float16); die rohe Datei nur bis zum Umwandeln.
    var encoderFile: URL { directory.appendingPathComponent("vae-encoder-2d.safetensors") }
    var encoderRawFile: URL { directory.appendingPathComponent("vae-encoder-raw.safetensors") }
    var configFile: URL { directory.appendingPathComponent("config.json") }
    /// 13B: die fp8-Tensoren bis zum Umwandeln, danach die Teile in 4 oder 8 Bit samt Liste.
    var rawDitFile: URL { directory.appendingPathComponent("dit-fp8.safetensors") }
    var shardList: URL { directory.appendingPathComponent("dit-q\(bits ?? 0).json") }

    /// Die Transformer-Dateien: beim 2B eine, beim 13B die umgewandelten Teile (Liste wird erst nach dem Umwandeln
    /// geschrieben).
    var ditFiles: [URL] {
        guard is13B else { return [directory.appendingPathComponent("dit.safetensors")] }
        guard let data = try? Data(contentsOf: shardList), let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names.map { directory.appendingPathComponent($0) }
    }

    /// Abschnitt `vae` der Einstellungen (Aufbau des Encoders); nil = Aufbau von 0.9.5 bis 0.9.8.
    var vaeConfig: [String: Any]? {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return config["vae"] as? [String: Any]
    }

    /// Ungefähre Download-Größe: Transformer, Decoder 1,11, Encoder roh 1,39, T5 2,68 GB.
    var bytes: Int64 {
        isLTX2 ? ditDownloadBytes : ditDownloadBytes + 1_105_600_000 + VideoCatalog.encoderBytes + 2_679_190_491 + 1_400_000
    }
    var downloadGB: Double { (Double(bytes) / 1e7).rounded() / 100 }
    /// Auf der Platte: der Encoder umgewandelt mit 0,46 statt 1,39 GB, der 13B-Transformer in 4 oder 8 Bit.
    var diskGB: Double {
        if isLTX2 { return (Double(ditDiskBytes) / 1e7).rounded() / 100 }
        return (Double(ditDiskBytes + 1_105_600_000 + 2_679_190_491 + (encoderInstalled ? 462_000_000 : 0)) / 1e7).rounded() / 100
    }

    var installed: Bool {
        if isLTX2 { return FileManager.default.fileExists(atPath: LTX2Engine.marker(self).path) }
        let dit = ditFiles
        return !dit.isEmpty && dit.allSatisfy { HFRange.complete($0) } && HFRange.complete(decoderFile)
            && VideoCatalog.textEncoderInstalled
    }

    /// Startbild möglich (seit 0.4.8; ältere Installationen holen den Encoder per „Herunterladen“ nach).
    var encoderInstalled: Bool { isLTX2 ? installed : HFRange.complete(encoderFile) }

    var name: String {
        if ltx2 == "distilled" { return t("LTX-2.3 mit Ton (distilled, 4 Bit)", "LTX-2.3 with sound (distilled, 4-bit)") }
        if isLTX2 { return t("LTX-2.5 mit Ton (distilled, 8 Bit)", "LTX-2.5 with sound (distilled, 8-bit)") }
        switch bits {
        case 4?: return t("LTX-Video 13B (0.9.8 distilled, 4 Bit)", "LTX-Video 13B (0.9.8 distilled, 4-bit)")
        case 8?: return t("LTX-Video 13B (0.9.8 distilled, 8 Bit)", "LTX-Video 13B (0.9.8 distilled, 8-bit)")
        default: return t("LTX-Video 2B (0.9.8 distilled)", "LTX-Video 2B (0.9.8 distilled)")
        }
    }

    var description: String {
        let license = t(" Lizenz: LTX-Video Open Weights License, kostenlos unter 10 Mio. US-$ Jahresumsatz; Weitergegebenes "
                        + "als KI-erzeugt kennzeichnen.",
                        " License: LTX-Video Open Weights License, free below US$10M annual revenue; mark distributed videos "
                        + "as AI-generated.")
        if isLTX2 {
            return t("\(name) von Lightricks über ltx-video-swift-mlx (MIT): Bild und Ton in einem Durchgang, Text oder Startbild, "
                     + "zweistufig (acht Schritte, dann Hochskalieren). Ab \(minRAMGB) GB Arbeitsspeicher und macOS 26.3, Download "
                     + "rund \(Int(Double(ditDownloadBytes) / 1e9)) GB" + (gated ? ", gesperrtes Repo (Lizenz annehmen, Token in den Einstellungen)" : "")
                     + ". Auf dem Testgerät von NVAI-open (8 GB) nicht lauffähig: nicht gemessen. Lizenz: LTX-2 Community License, "
                     + "kostenlos unter 10 Mio. US-$ Jahresumsatz.",
                     "\(name) by Lightricks through ltx-video-swift-mlx (MIT): picture and sound in one pass, text or a start image, "
                     + "two stages (eight steps, then upscaling). From \(minRAMGB) GB of memory and macOS 26.3, download about "
                     + "\(Int(Double(ditDownloadBytes) / 1e9)) GB" + (gated ? ", gated repo (accept the license, token in the settings)" : "")
                     + ". Cannot run on NVAI-open's 8 GB test Mac: not measured. License: LTX-2 Community License, free below "
                     + "US$10M annual revenue.")
        }
        guard let bits else {
            return t("LTX-Video 2B von Lightricks: Text oder Startbild zu Video in acht Schritten, 24 Bilder je Sekunde, ohne Ton. "
                     + "Eigener MLX-Port von NVAI-open, gegen die Referenz geprüft. Der Text-Encoder ist T5-XXL in 4 Bit.",
                     "LTX-Video 2B by Lightricks: text or a start image to video in eight steps, 24 frames per second, no sound. "
                     + "NVAI-open's own MLX port, checked against the reference. The text encoder is T5-XXL in 4-bit.") + license
        }
        return t("LTX-Video 13B von Lightricks: dasselbe wie der 2B mit sechsfacher Rechenmenge je Schritt, für Macs ab "
                 + "\(minRAMGB) GB. Der Transformer kommt als fp8-Datei (13,2 GB) und wird beim Laden in \(bits) Bit umgewandelt "
                 + "(rund \(Int((Double(ditDiskBytes) / 1e9).rounded())) GB). Gegen die Referenz blockweise geprüft; "
                 + "Speicherbedarf und Zeiten sind geschätzt, NVAI-open hatte keinen so großen Mac zum Messen.",
                 "LTX-Video 13B by Lightricks: the same as the 2B with six times the computation per step, for Macs with "
                 + "\(minRAMGB) GB or more. The transformer comes as an fp8 file (13.2 GB) and is converted to \(bits)-bit on "
                 + "download (about \(Int((Double(ditDiskBytes) / 1e9).rounded())) GB). Checked block by block against the "
                 + "reference; memory and times are estimates, NVAI-open had no Mac this large to measure.") + license
    }

    /// Fläche × Bilder, die in den Speicher passen. 2B am 8-GB-M1 gemessen bis 768 × 512 × 97 (Spitze 6,2 GB); 13B
    /// geschätzt: dasselbe bei der kleinsten passenden Speichergröße, darüber wie beim 2B das Doppelte bzw. LTX'
    /// Empfehlung (unter 720 × 1280, unter 257 Bildern).
    var maxVoxels: Int {
        if isLTX2 {  // geschätzt: 768 × 512 × 121 bei der Mindestgröße, darüber 1024 × 576 × 241
            return SystemInfo.memoryGB < minRAMGB * 3 / 2 ? 768 * 512 * 121 : 1024 * 576 * 241
        }
        let measured = 768 * 512 * 97
        let ram = SystemInfo.memoryGB
        if ram <= minRAMGB { return measured }
        return ram <= max(16, minRAMGB * 2) ? 2 * measured : 1280 * 704 * 257
    }

    /// Formate des Modells: LTX-Video wie in Lightricks' Beispielen, LTX-2 in Vielfachen von 64.
    var sizes: [[String: Any]] {
        guard isLTX2 else { return VideoCatalog.sizes }
        return [
            ["label": t("768 × 512: Querformat", "768 × 512: landscape"), "w": 768, "h": 512],
            ["label": t("512 × 768: Hochformat", "512 × 768: portrait"), "w": 512, "h": 768],
            ["label": t("1024 × 576: Querformat 16:9", "1024 × 576: landscape 16:9"), "w": 1024, "h": 576],
            ["label": t("576 × 1024: Hochformat 9:16", "576 × 1024: portrait 9:16"), "w": 576, "h": 1024],
        ]
    }

    /// Lädt, was fehlt. 13B: Decoder und Encoder vom 2B übernehmen, wenn es da ist (byte-gleich), sonst aus der
    /// 13B-Datei; die fp8-Tensoren des Transformers in eine Datei, dann in Teile zu 4 oder 8 Bit umwandeln.
    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if isLTX2 { return try await LTX2Engine.download(self, progress: progress) }
        let total = Double(bytes)
        var before: Int64 = 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ltx = URL(string: "https://huggingface.co/\(VideoCatalog.ltxRepo)/resolve/\(VideoCatalog.ltxRevision)/\(ltxFile)")!
        let base = VideoModel.ltxv2B
        if is13B {
            // Platz: fp8-Tensoren und die umgewandelten Teile liegen kurz nebeneinander
            let need = (installed ? 0 : ditDownloadBytes + ditDiskBytes) + 3_000_000_000
            if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < need {
                throw APIError(507, t("Zu wenig Platz: Für \(name) braucht es beim Laden rund \(need / 1_000_000_000) GB frei.",
                                      "Not enough space: \(name) needs about \(need / 1_000_000_000) GB free while downloading."))
            }
            for (from, to) in [(base.decoderFile, decoderFile), (base.encoderFile, encoderFile)]
                where !HFRange.complete(to) && HFRange.complete(from) {
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        // 1. Transformer, Decoder und Bild-Encoder aus der Einzeldatei
        let ditDone = !ditFiles.isEmpty && ditFiles.allSatisfy { HFRange.complete($0) }
        if !ditDone || !HFRange.complete(decoderFile) || !encoderInstalled {
            let all = try await HFRange.tensors(ltx)
            let stats = all.filter { $0.key.hasPrefix("vae.per_channel_statistics.") }
            let dec = all.filter { $0.key.hasPrefix("vae.decoder.") } + stats
            let enc = all.filter { $0.key.hasPrefix("vae.encoder.") } + stats
            let dit = all.filter { $0.key.hasPrefix("model.diffusion_model.") }
            if !HFRange.complete(decoderFile) {
                let offset = before
                try await HFRange.write(dec.map { (ltx, $0) }, to: decoderFile) { done in
                    progress(Double(offset + done) / total, t("lädt den Video-Decoder", "downloading the video decoder"))
                }
            }
            before += dec.reduce(0) { $0 + $1.count }
            if !ditDone {
                let target = is13B ? rawDitFile : ditFiles[0]
                if !HFRange.complete(target) {
                    let offset = before
                    try await HFRange.write(dit.map { (ltx, $0) }, to: target) { done in
                        progress(Double(offset + done) / total, t("lädt den Transformer", "downloading the transformer"))
                    }
                }
                if let bits {
                    progress(Double(before + ditDownloadBytes) / total,
                             t("wandelt den Transformer in \(bits) Bit um", "converting the transformer to \(bits)-bit"))
                    for old in ditFiles { try? FileManager.default.removeItem(at: old) }
                    let shards = try LTXWeights.convertTransformer(source: rawDitFile, to: directory, bits: bits,
                                                                   prefix: "dit-q\(bits)") { done, count in
                        progress(Double(before + ditDownloadBytes) / total,
                                 t("wandelt den Transformer in \(bits) Bit um (\(done)/\(count))",
                                   "converting the transformer to \(bits)-bit (\(done)/\(count))"))
                    }
                    Memory.clearCache()
                    try JSONEncoder().encode(shards.map(\.lastPathComponent)).write(to: shardList)
                    try? FileManager.default.removeItem(at: rawDitFile)
                }
            }
            before += ditDownloadBytes
            if !encoderInstalled {
                if !HFRange.complete(encoderRawFile) {
                    let offset = before
                    try await HFRange.write(enc.map { (ltx, $0) }, to: encoderRawFile) { done in
                        progress(Double(offset + done) / total,
                                 t("lädt den Bild-Encoder (Startbild)", "downloading the image encoder (start image)"))
                    }
                }
                progress(Double(before + enc.reduce(0) { $0 + $1.count }) / total,
                         t("wandelt den Bild-Encoder um", "converting the image encoder"))
                try convertEncoder()
            }
            before += enc.reduce(0) { $0 + $1.count }
        } else {
            before += ditDownloadBytes + 1_105_600_000 + VideoCatalog.encoderBytes
        }
        if !FileManager.default.fileExists(atPath: configFile.path) {
            // Die Einstellungen der Einzeldatei (Metadaten „config“) als config.json.
            let n = Int64(HFRange.littleEndian(try await HFRange.data(ltx, 0, 8)))
            if let header = try JSONSerialization.jsonObject(with: try await HFRange.data(ltx, 8, n)) as? [String: Any],
               let meta = header["__metadata__"] as? [String: String], let config = meta["config"] {
                try config.write(to: configFile, atomically: true, encoding: .utf8)
            }
        }
        try await VideoCatalog.downloadTextEncoder(before: before, total: total, progress: progress)
        progress(1, t("fertig", "done"))
    }

    /// Die rohen 3D-Kerne über die Zeit aufsummiert als 2D-Kerne in float16, dann die rohe Datei weg (~1 s).
    func convertEncoder() throws {
        let tmp = directory.appendingPathComponent("vae-encoder-2d.part.safetensors")
        try LTXWeights.convertImageEncoder(raw: encoderRawFile, to: tmp)
        Memory.clearCache()
        try? FileManager.default.removeItem(at: encoderFile)
        try FileManager.default.moveItem(at: tmp, to: encoderFile)
        try? FileManager.default.removeItem(at: encoderRawFile)
    }

    /// Löscht das Modell; T5 erst, wenn kein anderes Videomodell ihn mehr braucht (sonst nutzt ihn kein Modell).
    func delete() {
        if isLTX2 { return LTX2Engine.delete(self) }
        try? FileManager.default.removeItem(at: directory)
        if !VideoCatalog.models.contains(where: { $0.id != id && $0.installed }) {
            try? FileManager.default.removeItem(at: VideoCatalog.t5Root)
        }
    }

    var info: [String: Any] {
        let ok = installed
        var features: [String: Any] = [
            "steps": 8, "cfg": 1.0, "fps": VideoCatalog.fps, "frames": VideoCatalog.frameChoices, "sizes": sizes,
            "image_to_video": ok && encoderInstalled, "audio": hasAudio, "max_voxels": maxVoxels,
            "prompt_hint": t("Ein Absatz im Präsens: Einstellung, Ort und Licht, die Handlung mit Verben, dann die Kamera.",
                             "One paragraph in the present tense: shot, setting and light, the action with verbs, then the camera."),
        ]
        // Wie unter Windows: eine Zusatzfunktion, deren Dateien fehlen, steht unter "missing" mit ihrer Quelle.
        if ok && !encoderInstalled { features["missing"] = ["image_to_video": "https://huggingface.co/\(VideoCatalog.ltxRepo)"] }
        let fit = MacFit.of(needGB: needGB)
        return [
            "id": id, "name": name, "kind": "video", "family": "ltxv", "workflow": "ltxv_distilled",
            "files": [["repo": VideoCatalog.ltxRepo, "file": ltxFile, "target": "video", "installed": ok,
                       "local_path": directory.path] as [String: Any]],
            "size_gb": downloadGB, "vram_gb": minRAMGB,
            "license": isLTX2 ? "LTX-2 Community License" : "LTX-Video Open Weights License 0.X", "commercial_ok": true,
            "gated": gated, "min_macos": isLTX2 ? "26.3" : "15.0",
            "warning": t("Kostenlos nur unter 10 Mio. US-$ Jahresumsatz; weitergegebene Videos als KI-erzeugt kennzeichnen.",
                         "Free only below US$10M annual revenue; mark distributed videos as AI-generated."),
            "best_for": is13B ? t("Mehr Detail und Bewegung auf Macs ab \(minRAMGB) GB", "More detail and motion on Macs with \(minRAMGB) GB or more")
                : t("Kurze Clips aus Text oder einem Startbild", "Short clips from text or a start image"),
            "description": description,
            "pros": [String](), "cons": [String](), "installed": ok, "partially_installed": false,
            "disk_gb": ok ? diskGB : 0, "runnable": ok, "favorite": false, "fits_vram": fit, "engine": "mlx",
            "recommended": VideoCatalog.recommended.id == id,
            "gpu_note": isLTX2 && !LTX2Engine.osSupported ? t("Braucht macOS 26.3.", "Needs macOS 26.3.") : (is13B || isLTX2) ? t("Speicherbedarf geschätzt (\(String(format: "%.1f", needGB)) GB), auf einem Mac dieser Größe nicht gemessen.",
                                  "Memory need estimated (\(String(format: "%.1f", needGB)) GB), not measured on a Mac this size.") : "",
            "features": features,
        ]
    }
}

enum VideoCatalog {
    static let ltxRepo = "Lightricks/LTX-Video"
    static let ltxRevision = "8984fa25007f376c1a299016d0957a37a2f797bb"
    static let t5Repo = "dhairyashil/FLUX.1-schnell-mflux-4bit"
    static let t5Revision = "0e0b247ac48b8bf86fd5b440813b7da5854e238b"
    static let tokenizerRepo = "google-t5/t5-base"
    static let tokenizerRevision = "a9723ea7f1b39c1eae772870f3b547bf6ef7e6c1"
    /// Rohe Encoder-Tensoren samt Kanalstatistik (bf16, 3D-Kerne).
    static let encoderBytes: Int64 = 1_388_211_370

    static let models: [VideoModel] = [.ltxv2B, .ltxv13BQ4, .ltxv13BQ8, .ltx23, .ltx25]
    static func model(_ id: String) -> VideoModel? { models.first { $0.id == id } }
    static var installedModels: [VideoModel] { models.filter(\.installed) }
    static var anyInstalled: Bool { models.contains(where: \.installed) }

    /// Empfehlung nach Arbeitsspeicher: das größte Modell, dessen Mindestgröße der Mac erreicht (8–15 GB 2B,
    /// 16–23 GB 13B in 4 Bit, 24–31 GB 13B in 8 Bit, 32–63 GB LTX-2.3 mit Ton, ab 64 GB LTX-2.5 mit Ton; LTX-2 nur ab
    /// macOS 26.3).
    static var recommended: VideoModel {
        models.filter { SystemInfo.memoryGB >= $0.minRAMGB && (!$0.isLTX2 || LTX2Engine.osSupported) }
            .max { $0.minRAMGB < $1.minRAMGB } ?? .ltxv2B
    }

    /// Das Modell für Aufträge ohne `model_id`: die Wahl im Formular, wenn geladen, sonst das empfohlene, wenn
    /// geladen, sonst irgendein geladenes, sonst der 2B.
    static var active: VideoModel {
        if let chosen = UserDefaults.standard.string(forKey: "video.model").flatMap(model), chosen.installed { return chosen }
        if recommended.installed { return recommended }
        return installedModels.max { $0.minRAMGB < $1.minRAMGB } ?? .ltxv2B
    }

    static var t5Root: URL { Settings.modelsDirectory.appendingPathComponent(t5Repo) }
    static var t5Directory: URL { t5Root.appendingPathComponent("text_encoder_2") }
    static var tokenizerDirectory: URL { t5Root.appendingPathComponent("nvai/tokenizer") }
    static var t5BiasFile: URL { t5Root.appendingPathComponent("nvai/t5-relative-bias.safetensors") }
    static let t5Files: [(name: String, bytes: Int64)] = [("0.safetensors", 2_145_878_330), ("1.safetensors", 533_312_161)]

    static var textEncoderInstalled: Bool {
        HFRange.complete(t5BiasFile)
            && FileManager.default.fileExists(atPath: tokenizerDirectory.appendingPathComponent("tokenizer.json").path)
            && t5Files.allSatisfy { HFRange.complete(t5Directory.appendingPathComponent($0.name)) }
    }

    /// T5 in 4 Bit, Tokenizer und Positions-Tabelle (für alle Videomodelle gleich).
    static func downloadTextEncoder(before start: Int64, total: Double,
                                    progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var before = start
        for file in t5Files {
            let target = t5Directory.appendingPathComponent(file.name)
            if !HFRange.complete(target) {
                try FileManager.default.createDirectory(at: t5Directory, withIntermediateDirectories: true)
                let url = URL(string: "https://huggingface.co/\(t5Repo)/resolve/\(t5Revision)/text_encoder_2/\(file.name)")!
                let offset = before
                let tmp = try await Downloader().lade(url) { stand in
                    progress(Double(offset + stand.geladen) / total, t("lädt den Text-Encoder", "downloading the text encoder"))
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
            }
            before += file.bytes
        }
        // Tokenizer (t5-base hat keine tokenizer_config.json) und die Positions-Tabelle in float32
        let tokenizer = tokenizerDirectory.appendingPathComponent("tokenizer.json")
        if !FileManager.default.fileExists(atPath: tokenizer.path) {
            try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(tokenizerRepo)/resolve/\(tokenizerRevision)/tokenizer.json")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw APIError(502, t("Tokenizer nicht erreichbar.", "Tokenizer not reachable."))
            }
            try data.write(to: tokenizer)
            let config = #"{"tokenizer_class": "T5Tokenizer", "model_max_length": 512, "eos_token": "</s>", "pad_token": "<pad>", "unk_token": "<unk>"}"#
            try config.write(to: tokenizerDirectory.appendingPathComponent("tokenizer_config.json"), atomically: true, encoding: .utf8)
        }
        if !HFRange.complete(t5BiasFile) {
            let key = "encoder.block.0.layer.0.SelfAttention.relative_attention_bias.weight"
            let index = URL(string: "https://huggingface.co/\(ltxRepo)/resolve/\(ltxRevision)/text_encoder/model.safetensors.index.json")!
            let (data, _) = try await URLSession.shared.data(from: index)
            guard let map = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["weight_map"] as? [String: String],
                  let shard = map[key] else { throw APIError(502, t("T5-Index unlesbar.", "Unreadable T5 index.")) }
            let url = URL(string: "https://huggingface.co/\(ltxRepo)/resolve/\(ltxRevision)/text_encoder/\(shard)")!
            guard let tensor = try await HFRange.tensors(url).first(where: { $0.key == key }) else {
                throw APIError(502, t("Positions-Tabelle fehlt.", "Position table missing."))
            }
            let renamed = HFRange.Tensor(key: "relative_attention_bias.weight", dtype: tensor.dtype, shape: tensor.shape,
                                         start: tensor.start, count: tensor.count)
            try await HFRange.write([(url, renamed)], to: t5BiasFile) { _ in }
        }
    }

    /// Formate (Vielfache von 32) und Längen (8n + 1 Bilder) wie in Lightricks' Beispielen.
    static var sizes: [[String: Any]] {
        [
            ["label": t("768 × 512: Querformat", "768 × 512: landscape"), "w": 768, "h": 512],
            ["label": t("512 × 768: Hochformat", "512 × 768: portrait"), "w": 512, "h": 768],
            ["label": t("704 × 480: Querformat, kleiner", "704 × 480: landscape, smaller"), "w": 704, "h": 480],
            ["label": t("512 × 320: schnell, für 8-GB-Macs", "512 × 320: fast, for 8 GB Macs"), "w": 512, "h": 320],
        ]
    }

    static let fps = 24
    static let frameChoices = [25, 49, 97, 121]

    /// Videomodelle zur Auswahl im Formular. `startImage`: nimmt das Modell ein Startbild (true), nicht (false) oder
    /// ist das ungeprüft (nil)? Die Oberfläche graut das Startbild bei false aus und zeigt bei nil einen Hinweis.
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        let startImage: Bool?
    }

    /// Die geladenen Videomodelle (ohne geladenes: der 2B, damit das Formular einen Namen zeigt).
    static var choices: [Choice] {
        let list = installedModels.isEmpty ? [VideoModel.ltxv2B] : installedModels
        return list.map { Choice(id: $0.id, name: $0.name, startImage: true) }
    }
}
