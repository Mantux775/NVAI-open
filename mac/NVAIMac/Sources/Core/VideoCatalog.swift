import Foundation
import LTXV
import MLX

/// Video (seit 0.4.8): LTX-Video 2B 0.9.8 distilled (Lightricks) über den eigenen MLX-Port `Packages/ltxv-swift`.
/// Text oder Startbild zu Video in acht Schritten ohne Gewichtung, 24 Bilder je Sekunde, ohne Ton. Geladen werden
/// Transformer, VAE-Decoder und VAE-Encoder per Byte-Bereich aus Lightricks' Einzeldatei, der T5-XXL-Text-Encoder in
/// der 4-Bit-Fassung von mflux (2,7 GB; bitgleich mit LTX-Videos T5, geprüft an der letzten Norm), dazu sein Tokenizer
/// (google-t5/t5-base) und die Positions-Tabelle in float32. Der Encoder (nur fürs Startbild) kommt roh mit 1,39 GB
/// und wird einmal auf 2D-Kerne in float16 umgewandelt (0,46 GB, `LTXWeights.convertImageEncoder`). Wer das Modell vor
/// dem Startbild geladen hat, holt mit demselben Download nur den Encoder nach; `installed` verlangt ihn deshalb nicht.
enum VideoCatalog {
    static let id = "ltxv-2b-0.9.8-distilled"
    static let ltxRepo = "Lightricks/LTX-Video"
    static let ltxRevision = "8984fa25007f376c1a299016d0957a37a2f797bb"
    static let ltxFile = "ltxv-2b-0.9.8-distilled.safetensors"
    static let t5Repo = "dhairyashil/FLUX.1-schnell-mflux-4bit"
    static let t5Revision = "0e0b247ac48b8bf86fd5b440813b7da5854e238b"
    static let tokenizerRepo = "google-t5/t5-base"
    static let tokenizerRevision = "a9723ea7f1b39c1eae772870f3b547bf6ef7e6c1"

    /// Ungefähre Download-Größe (Transformer 3,85, Decoder 1,11, Encoder roh 1,39, T5 2,68 GB).
    static let bytes: Int64 = 3_846_800_000 + 1_105_600_000 + encoderBytes + 2_679_190_491 + 1_400_000
    /// Rohe Encoder-Tensoren samt Kanalstatistik (bf16, 3D-Kerne).
    static let encoderBytes: Int64 = 1_388_211_370

    static var directory: URL { Settings.modelsDirectory.appendingPathComponent("\(ltxRepo)/\(id)") }
    static var ditFile: URL { directory.appendingPathComponent("dit.safetensors") }
    static var decoderFile: URL { directory.appendingPathComponent("vae-decoder.safetensors") }
    /// Der Bild-Encoder fürs Startbild, umgewandelt (2D-Kerne, float16); die rohe Datei nur bis zum Umwandeln.
    static var encoderFile: URL { directory.appendingPathComponent("vae-encoder-2d.safetensors") }
    static var encoderRawFile: URL { directory.appendingPathComponent("vae-encoder-raw.safetensors") }
    static var configFile: URL { directory.appendingPathComponent("config.json") }
    /// Abschnitt `vae` der Einstellungen (Aufbau des Encoders); nil = Aufbau von 0.9.5 bis 0.9.8.
    static var vaeConfig: [String: Any]? {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return config["vae"] as? [String: Any]
    }
    static var t5Root: URL { Settings.modelsDirectory.appendingPathComponent(t5Repo) }
    static var t5Directory: URL { t5Root.appendingPathComponent("text_encoder_2") }
    static var tokenizerDirectory: URL { t5Root.appendingPathComponent("nvai/tokenizer") }
    static var t5BiasFile: URL { t5Root.appendingPathComponent("nvai/t5-relative-bias.safetensors") }
    static let t5Files: [(name: String, bytes: Int64)] = [("0.safetensors", 2_145_878_330), ("1.safetensors", 533_312_161)]

    static var downloadGB: Double { (Double(bytes) / 1e7).rounded() / 100 }
    /// Auf der Platte: der Encoder umgewandelt mit 0,46 statt 1,39 GB.
    static var diskGB: Double {
        (Double(bytes - encoderBytes + (encoderInstalled ? 462_000_000 : 0)) / 1e7).rounded() / 100
    }

    static var installed: Bool {
        HFRange.complete(ditFile) && HFRange.complete(decoderFile) && HFRange.complete(t5BiasFile)
            && FileManager.default.fileExists(atPath: tokenizerDirectory.appendingPathComponent("tokenizer.json").path)
            && t5Files.allSatisfy { HFRange.complete(t5Directory.appendingPathComponent($0.name)) }
    }

    /// Startbild möglich (seit 0.4.8; ältere Installationen holen den Encoder per „Herunterladen“ nach).
    static var encoderInstalled: Bool { HFRange.complete(encoderFile) }

    /// Die rohen 3D-Kerne über die Zeit aufsummiert als 2D-Kerne in float16, dann die rohe Datei weg (~1 s).
    static func convertEncoder() throws {
        let tmp = directory.appendingPathComponent("vae-encoder-2d.part.safetensors")
        try LTXWeights.convertImageEncoder(raw: encoderRawFile, to: tmp)
        Memory.clearCache()
        try? FileManager.default.removeItem(at: encoderFile)
        try FileManager.default.moveItem(at: tmp, to: encoderFile)
        try? FileManager.default.removeItem(at: encoderRawFile)
    }

    static func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let total = Double(bytes)
        var before: Int64 = 0
        // 1. Transformer, Decoder und Bild-Encoder aus der Einzeldatei
        let ltx = URL(string: "https://huggingface.co/\(ltxRepo)/resolve/\(ltxRevision)/\(ltxFile)")!
        if !HFRange.complete(ditFile) || !HFRange.complete(decoderFile) || !encoderInstalled {
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
            if !HFRange.complete(ditFile) {
                let offset = before
                try await HFRange.write(dit.map { (ltx, $0) }, to: ditFile) { done in
                    progress(Double(offset + done) / total, t("lädt den Transformer", "downloading the transformer"))
                }
            }
            before += dit.reduce(0) { $0 + $1.count }
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
            before += 3_846_800_000 + 1_105_600_000 + encoderBytes
        }
        if !FileManager.default.fileExists(atPath: configFile.path) {
            // Die Einstellungen der Einzeldatei (Metadaten „config“) als config.json.
            let n = Int64(HFRange.littleEndian(try await HFRange.data(ltx, 0, 8)))
            if let header = try JSONSerialization.jsonObject(with: try await HFRange.data(ltx, 8, n)) as? [String: Any],
               let meta = header["__metadata__"] as? [String: String], let config = meta["config"] {
                try config.write(to: configFile, atomically: true, encoding: .utf8)
            }
        }
        // 2. T5 in 4 Bit
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
        // 3. Tokenizer (t5-base hat keine tokenizer_config.json) und die Positions-Tabelle in float32
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
        progress(1, t("fertig", "done"))
    }

    /// Löscht LTX-Video samt T5 (den nutzt sonst kein Modell der Mac-Fassung).
    static func delete() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: t5Root)
    }

    static var name: String { t("LTX-Video 2B (0.9.8 distilled)", "LTX-Video 2B (0.9.8 distilled)") }

    static var description: String {
        t("LTX-Video 2B von Lightricks: Text oder Startbild zu Video in acht Schritten, 24 Bilder je Sekunde, ohne Ton. "
          + "Eigener MLX-Port von NVAI-open, gegen die Referenz geprüft. Der Text-Encoder ist T5-XXL in 4 Bit. Lizenz: "
          + "LTX-Video Open Weights License, kostenlos unter 10 Mio. US-$ Jahresumsatz; Weitergegebenes als KI-erzeugt "
          + "kennzeichnen.",
          "LTX-Video 2B by Lightricks: text or a start image to video in eight steps, 24 frames per second, no sound. "
          + "NVAI-open's own MLX port, checked against the reference. The text encoder is T5-XXL in 4-bit. License: "
          + "LTX-Video Open Weights License, free below US$10M annual revenue; mark distributed videos as AI-generated.")
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

    static var choices: [Choice] { [Choice(id: id, name: name, startImage: true)] }

    static var info: [String: Any] {
        let ok = installed
        var features: [String: Any] = [
            "steps": 8, "cfg": 1.0, "fps": fps, "frames": frameChoices, "sizes": sizes,
            "image_to_video": ok && encoderInstalled, "audio": false,
            "prompt_hint": t("Ein Absatz im Präsens: Einstellung, Ort und Licht, die Handlung mit Verben, dann die Kamera.",
                             "One paragraph in the present tense: shot, setting and light, the action with verbs, then the camera."),
        ]
        // Wie unter Windows: eine Zusatzfunktion, deren Dateien fehlen, steht unter "missing" mit ihrer Quelle.
        if ok && !encoderInstalled { features["missing"] = ["image_to_video": "https://huggingface.co/\(ltxRepo)"] }
        return [
            "id": id, "name": name, "kind": "video", "family": "ltxv", "workflow": "ltxv_distilled",
            "files": [["repo": ltxRepo, "file": ltxFile, "target": "video", "installed": ok,
                       "local_path": directory.path] as [String: Any]],
            "size_gb": downloadGB, "vram_gb": 8, "license": "LTX-Video Open Weights License 0.X", "commercial_ok": true,
            "warning": t("Kostenlos nur unter 10 Mio. US-$ Jahresumsatz; weitergegebene Videos als KI-erzeugt kennzeichnen.",
                         "Free only below US$10M annual revenue; mark distributed videos as AI-generated."),
            "best_for": t("Kurze Clips aus Text oder einem Startbild", "Short clips from text or a start image"),
            "description": description,
            "pros": [String](), "cons": [String](), "installed": ok, "partially_installed": false,
            "disk_gb": ok ? diskGB : 0, "runnable": ok, "favorite": false, "fits_vram": "ja", "engine": "mlx",
            "features": features,
        ]
    }
}
