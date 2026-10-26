import Foundation

/// Z-Image Turbo (Tongyi-MAI, Apache-2.0) über MLX: das dritte Bildmodell neben FLUX.2 Klein und Core ML, über den
/// Swift-Port z-image-swift (`Packages/z-image-swift`). Geladen wird die vorquantisierte 4-Bit-Fassung von
/// mflux-community (5,9 GB statt 20,5 GB in bf16), dazu 0,28 GB Schichten in bf16 (`preciseFile`): mflux quantisiert
/// auch Ein- und Ausgabeschicht, Zeitsteuerung und AdaLN, das gab ein orangestichiges, verwaschenes Bild mit
/// 16-px-Raster. Turbo ist destilliert: 8 Schritte, keine Gewichtung (cfg 0), kein Negativprompt. Nur Text zu Bild.
struct ZImageModel: Identifiable, Sendable, Equatable {
    let id: String
    let repo: String
    let files: [String]
    let bytes: Int64

    var name: String { t("Z-Image Turbo (4 Bit)", "Z-Image Turbo (4-bit)") }
    var workflow: String { "z_image_turbo" }
    var downloadGB: Double { (Double(bytes + Self.preciseBytes) / 1e7).rounded() / 100 }
    var minRAMGB: Int { 8 }
    var recommendedRAMGB: Int { 16 }

    var directory: URL { Settings.modelsDirectory.appendingPathComponent(repo) }

    /// Die Schichten, die mflux mit quantisiert, der Port aber in bf16 hält (Ein- und Ausgabeschicht,
    /// Zeitsteuerung, Text-Projektion, AdaLN), aus mlx-community/Z-Image-Turbo-bf16 (siehe `downloadPrecise`).
    static let preciseFile = "nvai/dit-hp.safetensors"
    static let preciseRepo = "mlx-community/Z-Image-Turbo-bf16"
    /// Feste Revision: die Datei setzt sich aus Byte-Bereichen dieser Shards zusammen.
    static let preciseRevision = "0855b22d6384adae91cc365621c7c8f12c602070"
    static let preciseBytes: Int64 = 276_325_504

    /// Was der Port in bf16 hält (`ZImageWeights.keepHiPrecision`), unter den Namen der Originalgewichte.
    static func isPrecise(_ key: String) -> Bool {
        key.hasPrefix("all_x_embedder.") || key.hasPrefix("all_final_layer.") || key.hasPrefix("t_embedder.")
            || key.hasPrefix("cap_embedder.1.") || key.contains("adaLN_modulation.")
    }

    var installed: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("transformer/1.safetensors").path)
            && ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("transformer/0.safetensors").path))?[.size] as? Int64 ?? 0) > 2_000_000_000
            && preciseComplete
    }

    /// Die bf16-Datei ist vollständig, wenn sie genau Kopf plus `preciseBytes` lang ist.
    private var preciseComplete: Bool {
        let url = directory.appendingPathComponent(Self.preciseFile)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              let file = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 8), head.count == 8 else { return false }
        return size == 8 + Int64(Self.littleEndian(head)) + Self.preciseBytes
    }

    private static func littleEndian(_ bytes: Data) -> UInt64 {
        bytes.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    var bestFor: String {
        t("Fotorealistische Bilder und Schrift, schnell (8 Schritte)", "Photorealistic images and lettering, fast (8 steps)")
    }

    var description: String {
        t("Z-Image Turbo von Tongyi-MAI (Alibaba), Apache-2.0: ein 6-Mrd.-Parameter-Modell mit Qwen3-4B als Text-Encoder, "
          + "destilliert auf 8 Schritte. Als 4-Bit-Fassung von mflux-community, die empfindlichen Schichten (Ein- und "
          + "Ausgabe, Zeitsteuerung, Modulation) in bf16. Nur Text zu Bild (keine Referenzbilder, keine Maske, kein "
          + "Bild-zu-Bild), kein Negativprompt.",
          "Z-Image Turbo by Tongyi-MAI (Alibaba), Apache-2.0: a 6B-parameter model with Qwen3-4B as text encoder, "
          + "distilled to 8 steps. As the 4-bit build by mflux-community, with the sensitive layers (input and output, "
          + "timestep, modulation) in bf16. Text to image only (no reference images, no mask, no image-to-image), no "
          + "negative prompt.")
    }

    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let sizes: [String: Int64] = ["transformer/0.safetensors": 2_140_200_000, "transformer/1.safetensors": 1_323_500_000,
                                      "text_encoder/0.safetensors": 2_135_400_000, "text_encoder/1.safetensors": 127_600_000,
                                      "vae/0.safetensors": 164_700_000]
        var before: Int64 = 0
        for file in files {
            let target = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let expected = sizes[file] ?? 0
            let have = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? 0
            if !(have > 0 && Double(have) >= Double(expected) * 0.95) {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
                let offset = before
                let tmp = try await Downloader().lade(url) { stand in
                    progress(Double(offset + stand.geladen) / Double(bytes), t("lädt \(file)", "downloading \(file)"))
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
            }
            before += expected
        }
        if !preciseComplete {
            let total = Double(bytes + Self.preciseBytes)
            let offset = before
            try await downloadPrecise { done in
                progress(Double(offset + done) / total, t("lädt bf16-Schichten", "downloading bf16 layers"))
            }
        }
        progress(1, t("fertig", "done"))
    }

    /// Holt nur die bf16-Tensoren aus `isPrecise` per HTTP-Range aus den drei Shards von `preciseRepo` (0,28 statt
    /// 12,3 GB) und schreibt sie als eigene safetensors-Datei.
    func downloadPrecise(progress: @escaping @Sendable (Int64) -> Void) async throws {
        struct Part { let key: String; let url: URL; let start: Int64; let count: Int64; let dtype: String; let shape: [Int] }
        let base = "https://huggingface.co/\(Self.preciseRepo)/resolve/\(Self.preciseRevision)/transformer/"
        var parts: [Part] = []
        for shard in 1 ... 3 {
            let url = URL(string: base + String(format: "diffusion_pytorch_model-%05d-of-00003.safetensors", shard))!
            let n = Int64(Self.littleEndian(try await Self.range(url, 0, 8)))
            guard n > 0, n < 10_000_000,
                  let header = try JSONSerialization.jsonObject(with: try await Self.range(url, 8, n)) as? [String: Any]
            else {
                throw APIError(502, t("Kopf von \(url.lastPathComponent) unlesbar.", "Unreadable header of \(url.lastPathComponent)."))
            }
            for (key, value) in header where key != "__metadata__" && Self.isPrecise(key) {
                guard let v = value as? [String: Any], let dtype = v["dtype"] as? String, let shape = v["shape"] as? [Int],
                      let offsets = v["data_offsets"] as? [Int], offsets.count == 2 else { continue }
                parts.append(Part(key: key, url: url, start: 8 + n + Int64(offsets[0]),
                                  count: Int64(offsets[1] - offsets[0]), dtype: dtype, shape: shape))
            }
        }
        parts.sort { $0.key < $1.key }
        guard parts.reduce(Int64(0), { $0 + $1.count }) == Self.preciseBytes else {
            throw APIError(502, t("Die bf16-Schichten haben eine unerwartete Größe.", "The bf16 layers have an unexpected size."))
        }
        var header: [String: Any] = [:]
        var position = 0
        for part in parts {
            header[part.key] = ["dtype": part.dtype, "shape": part.shape, "data_offsets": [position, position + Int(part.count)]]
            position += Int(part.count)
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }
        let target = directory.appendingPathComponent(Self.preciseFile)
        let tmp = target.appendingPathExtension("part")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let file = try FileHandle(forWritingTo: tmp)
        var length = UInt64(json.count).littleEndian
        try file.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try file.write(contentsOf: json)
        var done: Int64 = 0
        for part in parts {
            try Task.checkCancellation()
            try file.write(contentsOf: try await Self.range(part.url, part.start, part.count))
            done += part.count
            progress(done)
        }
        try file.close()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    /// Ein Byte-Bereich; bis zu drei Versuche. Ein Server ohne Range-Unterstützung (200 statt 206) bricht ab.
    private static func range(_ url: URL, _ start: Int64, _ count: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        var lastError: Error = APIError(502, "range")
        for attempt in 0 ..< 3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 206, Int64(data.count) == count else {
                    throw APIError(502, t("Hugging Face lieferte keinen Teilbereich (HTTP \(status)).",
                                          "Hugging Face returned no partial content (HTTP \(status))."))
                }
                return data
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                if attempt < 2 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError
    }

    func delete() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum ZImageCatalog {
    static let all: [ZImageModel] = [
        ZImageModel(
            id: "z-image-turbo-q4", repo: "mflux-community/z-image-turbo-mflux-q4",
            files: ["tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "tokenizer/chat_template.jinja",
                    "text_encoder/model.safetensors.index.json", "transformer/model.safetensors.index.json",
                    "vae/model.safetensors.index.json", "vae/0.safetensors", "text_encoder/1.safetensors",
                    "text_encoder/0.safetensors", "transformer/1.safetensors", "transformer/0.safetensors"],
            bytes: 5_900_000_000),
    ]

    static func model(_ id: String?) -> ZImageModel? { all.first { $0.id == id } }

    static func fits(_ m: ZImageModel) -> String {
        SystemInfo.memoryGB >= m.recommendedRAMGB ? "ja" : SystemInfo.memoryGB >= m.minRAMGB ? "knapp" : "nein"
    }

    static func warning(_ m: ZImageModel) -> String {
        SystemInfo.memoryGB < m.recommendedRAMGB
            ? t("Läuft mit \(SystemInfo.memoryGB) GB, aber knapp: Text-Encoder und Bildmodell laden nacheinander.",
                "Runs with \(SystemInfo.memoryGB) GB, but tight: text encoder and image model load one after another.")
            : ""
    }

    /// Am 8-GB-M1 gemessen bis 1024² (Spitze 5,4 GB); darüber die Grenze des Ports (1536², nach Fläche).
    static var maxPixels: Int { SystemInfo.memoryGB <= 8 ? 1024 * 1024 : 1536 * 1536 }

    static func features(_ m: ZImageModel) -> [String: Any] {
        [
            "steps": 8, "cfg": 0.0, "negative_prompt": false, "default_negative": "",
            "upsampler": false, "references": 0, "bbox": false, "img2img": false, "mask": false, "hires": false,
            "text_rendering": true, "outpaint": NSNull(),
            "sizes": ModelCatalog.flux2Sizes, "max_pixels": maxPixels,
            "prompt_hint": t("Ganze Sätze: Motiv mit Material, Farbe und Zustand, dann Stil, Licht und Hintergrund. Schrift "
                             + "in Anführungszeichen. 8 Schritte, kein Negativprompt.",
                             "Full sentences: the subject with material, color and condition, then style, lighting and "
                             + "background. Lettering in quotation marks. 8 steps, no negative prompt."),
            "placeholder": ModelCatalog.placeholder,
        ]
    }

    static func info(_ m: ZImageModel) -> [String: Any] {
        let ok = m.installed
        return [
            "id": m.id, "name": m.name, "kind": "image", "family": "z_image", "workflow": m.workflow,
            "files": m.files.filter { $0.hasSuffix(".safetensors") }.map {
                ["repo": m.repo, "file": $0, "target": "zimage", "installed": ok,
                 "local_path": m.directory.appendingPathComponent($0).path] as [String: Any]
            },
            "size_gb": m.downloadGB, "vram_gb": m.minRAMGB, "license": "Apache-2.0", "commercial_ok": true,
            "warning": warning(m), "best_for": m.bestFor, "description": m.description,
            "pros": [String](), "cons": [String](),
            "installed": ok, "partially_installed": false, "disk_gb": ok ? m.downloadGB : 0,
            "runnable": ok, "favorite": false, "fits_vram": fits(m), "features": features(m), "engine": "mlx",
        ].merging(ContentRating.apiFields(m.id)) { a, _ in a }
    }
}
