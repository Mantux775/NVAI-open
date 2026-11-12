import CryptoKit
import Foundation

/// Eigene LoRA-Dateien (seit 0.5.5, wie NVAI-open für Windows seit 0.5.24): erkennen, zu welchem Modell eine Datei
/// gehört, prüfen, ob sie vollständig ist, und sie ablegen. Die Erkennung folgt `server/nvai/loras.py`: Eine LoRA passt
/// nur zur Architektur (und Größe), auf der sie trainiert ist; das steht im safetensors-Kopf, an den Schlüsselnamen und
/// an der Breite der ersten LoRA-Matrix.
///
/// Auf dem Mac nimmt nur FLUX.2 Klein 4B LoRAs (flux-2-swift-mlx verrechnet sie beim Laden). Die Erkennung kennt
/// trotzdem alle Basen der Windows-Fassung, damit die Prüfung ehrlich sagt, wofür eine Datei ist, und dass es auf dem
/// Mac dafür kein Modell gibt. FLUX.2 Klein unterscheidet der Mac zusätzlich nach Größe (4B: Breite 3072, 9B: 4096):
/// Eine 9B-LoRA passt nicht auf den 4B-Transformer.
enum LoRAFiles {
    /// Größter plausibler safetensors-Kopf (wie unter Windows).
    static let headerLimit = 64 * 1024 * 1024
    static let suffix = ".safetensors"
    /// Wan 2.2 A14B: an welchen Experten eine LoRA geht (nur der Vollständigkeit halber; auf dem Mac gibt es kein Wan).
    static let experts = ["high", "low", "both"]

    /// LoRA-Basis → Anzeigename. Die Schlüssel der Windows-Fassung, dazu die beiden Größen von FLUX.2 Klein.
    static let labels: [String: String] = [
        "sdxl": "SDXL (Pony, Illustrious, NoobAI, Juggernaut …)",
        "sd15": "Stable Diffusion 1.5",
        "qwenimage": "Qwen-Image",
        "zimage": "Z-Image",
        "flux1": "FLUX.1 / Chroma",
        "flux2": "FLUX.2 Klein",
        "flux2-klein-4b": "FLUX.2 Klein 4B",
        "flux2-klein-9b": "FLUX.2 Klein 9B",
        "wan-1.3b": "Wan 2.1 1.3B",
        "wan-5b": "Wan 2.2 TI2V 5B",
        "wan-14b": "Wan 14B (2.1, 2.2 A14B)",
        "ltx2": "LTX-2 / LTX-2.3",
        "ltxv": "LTX-Video 0.9",
    ]

    static func label(_ base: String) -> String { labels[base] ?? base }

    /// Basen, die ein Modell dieses Macs nimmt. Nur FLUX.2 Klein 4B: Z-Image, LTX-Video und Core ML laden keine LoRAs;
    /// das LTX-2-Paket könnte es, ist aber erst ab 32 GB lauffähig und dafür nicht eingebaut.
    static var macBases: [String] { [LoRAModel.family] }

    /// Basis aus einer Anfrage: "flux2" (der Schlüssel der Windows-Fassung) meint auf dem Mac FLUX.2 Klein 4B.
    static func normalizedBase(_ value: String) -> String {
        value == "flux2" ? LoRAModel.family : value
    }

    /// Bildmodelle des Macs, die LoRAs dieser Basis nehmen (Namen), wie `lora_targets` unter Windows.
    static func targets(_ base: String?) -> [String] {
        guard let base, macBases.contains(base) else { return [] }
        return ModelCatalog.all.map(\.name)
    }

    static var directory: URL { Settings.modelsDirectory.appendingPathComponent("loras", isDirectory: true) }

    // MARK: Datei und Kopf

    static func invalid() -> APIError {
        APIError(400, t("Keine gültige safetensors-Datei.", "Not a valid safetensors file."))
    }

    /// Länge des JSON-Kopfs aus den ersten 8 Bytes (little endian).
    static func headerLength(_ first8: Data) throws -> Int {
        guard first8.count >= 8 else { throw invalid() }
        var n: UInt64 = 0
        for (i, byte) in first8.prefix(8).enumerated() { n |= UInt64(byte) << (8 * UInt64(i)) }
        guard n > 0, n <= UInt64(headerLimit) else { throw invalid() }
        return Int(n)
    }

    /// safetensors-Kopf aus dem Anfang einer Datei: 8 Byte Länge, dann der JSON-Kopf (Körper von /api/loras/inspect).
    static func header(from data: Data) throws -> [String: JSONValue] {
        let data = Data(data)  // eigene Indizes ab 0
        let n = try headerLength(data)
        guard data.count >= 8 + n, let head = JSON.parse(data.subdata(in: 8..<(8 + n)))?.objectValue else { throw invalid() }
        return head
    }

    /// Nur Länge und Kopf einer Datei lesen (Oberfläche: Prüfung vor dem Hinzufügen), ohne den Rest zu laden.
    static func readHeader(_ url: URL) throws -> (header: [String: JSONValue], length: Int) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw invalid() }
        defer { try? fh.close() }
        let n = try headerLength((try? fh.read(upToCount: 8)) ?? Data())
        let head = (try? fh.read(upToCount: n)) ?? Data()
        guard head.count == n, let parsed = JSON.parse(head)?.objectValue else { throw invalid() }
        return (parsed, n)
    }

    /// Kopf einer vollständigen Datei; wirft, wenn sie ungültig ist oder nicht genau so lang, wie ihr Kopf sagt
    /// (fehlende wie überzählige Bytes: so lehnt sie auch safetensors selbst ab).
    static func verifyFile(_ url: URL) throws -> [String: JSONValue] {
        let (head, n) = try readHeader(url)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == Int64(8 + n) + dataSize(head) else {
            throw APIError(400, t("Die Datei ist unvollständig oder beschädigt (Übertragung abgebrochen?).",
                                  "The file is incomplete or damaged (transfer interrupted?)."))
        }
        return head
    }

    /// Wie viele Bytes nach dem Kopf folgen müssen: das Ende des hintersten Tensors.
    static func dataSize(_ header: [String: JSONValue]) -> Int64 {
        var end: Int64 = 0
        for (key, meta) in header where key != "__metadata__" {
            if let offsets = meta["data_offsets"]?.arrayValue, offsets.count == 2, let last = offsets[1].intValue {
                end = max(end, Int64(last))
            }
        }
        return end
    }

    private static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"]
        + (0...9).map { "COM\($0)" } + (0...9).map { "LPT\($0)" })

    /// Dateiname für den Ordner loras/: nur der Name ohne Pfad, Sonderzeichen zu „_“, Endung .safetensors. Andere
    /// Formate (.pt, .ckpt, .bin) lädt NVAI-open nicht: Sie können beim Laden Code ausführen.
    static func fileName(_ name: String) throws -> String {
        let base = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        guard base.lowercased().hasSuffix(suffix) else {
            throw APIError(400, t("Nur .safetensors-Dateien lassen sich als LoRA hinzufügen.",
                                  "Only .safetensors files can be added as a LoRA."))
        }
        var stem = String(base.dropLast(suffix.count)).replacingOccurrences(of: "[^\\w.\\-]+", with: "_",
                                                                            options: .regularExpression)
        stem = String(stem.trimmingCharacters(in: CharacterSet(charactersIn: "._ ")).prefix(100))
        if stem.isEmpty { stem = "lora" }
        if reserved.contains(String(stem.split(separator: ".", omittingEmptySubsequences: false).first ?? "").uppercased()) {
            stem = "_" + stem  // Gerätenamen unter Windows (NUL.safetensors …): Dateien wandern zwischen beiden Systemen
        }
        return stem + suffix
    }

    /// Dateiname ohne Pfad und Endung, unverändert: Vorschlag für den Anzeigenamen.
    static func stem(_ name: String) -> String {
        let base = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        return base.lowercased().hasSuffix(suffix) ? String(base.dropLast(suffix.count)) : base
    }

    // MARK: Erkennen

    private static let prefixes = ["base_model_model_", "model_diffusion_model_", "diffusion_model_", "transformer_",
                                   "lora_unet_", "unet_"]

    /// Schlüssel vereinheitlicht wie `_norm` unter Windows: klein, Punkte und Striche zu „_“, ohne das Präfix des
    /// Formats (kohya, Diffusers, ComfyUI, PEFT).
    static func norm(_ key: String) -> String {
        let k = key.lowercased().replacingOccurrences(of: "[.\\-]", with: "_", options: .regularExpression)
        for p in prefixes where k.hasPrefix(p) {
            // "transformer." ist das Diffusers-Präfix, "transformer_blocks" ein echter Name
            if p == "transformer_" && k.hasPrefix("transformer_blocks") { continue }
            return String(k.dropFirst(p.count))
        }
        return k
    }

    private static func regex(_ pattern: String, lines: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: lines ? [.anchorsMatchLines] : [])
    }

    private static func contains(_ text: String, _ pattern: String, lines: Bool = false) -> Bool {
        guard let rx = regex(pattern, lines: lines) else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Alle Treffer der ersten Gruppe als Zahl.
    private static func numbers(_ text: String, _ pattern: String) -> [Int] {
        guard let rx = regex(pattern) else { return [] }
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    /// Eingangsbreite der ersten LoRA-Down-Matrix, deren Name auf `pattern` passt. Die Schlüssel laufen sortiert
    /// durch (Windows: in der Reihenfolge der Datei); bei echten LoRAs haben alle Treffer dieselbe Breite.
    static func inDim(_ header: [String: JSONValue], _ pattern: String) -> Int? {
        for key in header.keys.sorted() where key != "__metadata__" {
            let n = norm(key)
            guard contains(n, pattern), contains(n, "(lora_a|lora_down)_weight$"),
                  let shape = header[key]?["shape"]?.arrayValue, shape.count >= 2 else { continue }
            return shape[1].intValue
        }
        return nil
    }

    static func isLoRA(_ keys: [String]) -> Bool {
        keys.map { $0.lowercased() }.contains { k in
            k.contains(".lora_a.") || k.contains(".lora_b.") || k.contains("lora_down") || k.contains("lora_up")
                || k.contains(".lora.down.") || k.hasPrefix("lora_unet_") || k.hasPrefix("lora_te")
        }
    }

    private static func sentence(_ text: String) -> String {
        var s = text
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s + "."
    }

    /// (LoRA-Basis oder nil, Erklärung) aus einem safetensors-Kopf; Schritt für Schritt wie `detect` unter Windows,
    /// dazu die Größe bei FLUX.2 Klein.
    static func detect(_ header: [String: JSONValue]) -> (base: String?, why: String) {
        let keys = header.keys.filter { $0 != "__metadata__" }
        guard isLoRA(keys) else { return (nil, t("Keine LoRA.", "Not a LoRA.")) }
        let joined = keys.map(norm).sorted().joined(separator: "\n")
        func has(_ pattern: String) -> Bool { contains(joined, pattern, lines: true) }

        // SD-Familie: kohya-Namen oder Diffusers-UNet
        if keys.contains(where: { $0.lowercased().hasPrefix("lora_unet_") || $0.lowercased().hasPrefix("lora_te") })
            || has("(^|_)(input|down)_blocks_") {
            if has("^lora_te2_|^te2_") || has("input_blocks_[78]_1_transformer_blocks_[1-9]") {
                return ("sdxl", t("SDXL-LoRA", "SDXL LoRA"))
            }
            let dim = inDim(header, "attn2_to_k")
            if dim == 2048 || has("down_blocks_2_attentions_\\d_transformer_blocks_[1-9]") {
                return ("sdxl", t("SDXL-LoRA", "SDXL LoRA"))
            }
            if dim == 768 || has("down_blocks_0_attentions_0") || has("^lora_te_text_model|^te_text_model") {
                return ("sd15", t("SD-1.5-LoRA", "SD 1.5 LoRA"))
            }
        }
        // LTX-2 und LTX-Video: transformer_blocks.N.attn1
        if has("(^|_)transformer_blocks_\\d+_attn1_") {
            let dim = inDim(header, "transformer_blocks_\\d+_attn1_to_k")
            if dim == 4096 || has("audio_attn|audio_ff|audio_to_video") {
                return ("ltx2", t("LTX-2-LoRA (LTX-2, 2.3)", "LTX-2 LoRA (LTX-2, 2.3)"))
            }
            if dim == 2048 { return ("ltxv", t("LTX-Video-0.9-LoRA", "LTX-Video 0.9 LoRA")) }
        }
        // Wan: blocks.N.cross_attn / self_attn (ohne transformer_)
        if has("(^|_)blocks_\\d+_(cross_attn|self_attn)_") && !has("transformer_blocks_") {
            let dim = inDim(header, "blocks_\\d+_(self_attn|cross_attn)_[qkvo]")
            if let base = [1536: "wan-1.3b", 3072: "wan-5b", 5120: "wan-14b"][dim ?? 0] {
                return (base, t("Wan-LoRA (\(label(base)))", "Wan LoRA (\(label(base)))"))
            }
            let width = dim.map(String.init) ?? "None"
            return (nil, t("Wan-LoRA unbekannter Größe (Breite \(width)).", "Wan LoRA of unknown size (width \(width))."))
        }
        // Z-Image: layers.N.attention + adaLN
        if has("(^|_)layers_\\d+_attention_") && has("adaln_modulation") {
            return ("zimage", t("Z-Image-LoRA", "Z-Image LoRA"))
        }
        // FLUX.2 Klein vor FLUX.1: eigene Modulations- und Fused-Schichten
        if has("double_stream_modulation|single_stream_modulation|to_qkv_mlp_proj") { return flux2Size(header, joined) }
        if has("(^|_)(double_blocks|single_blocks|single_transformer_blocks)_\\d+_") {
            // FLUX.2 Klein hat 5 (4B) bzw. 8 (9B) Doppel- und 20 bzw. 24 Einzelblöcke, FLUX.1 und Chroma 19 und 38
            let doubles = numbers(joined, "(?:double_blocks|(?<!single_)transformer_blocks)_(\\d+)_")
            let singles = numbers(joined, "single_(?:transformer_)?blocks_(\\d+)_")
            if let d = doubles.max(), d < 8, (singles.max() ?? 0) < 24 { return flux2Size(header, joined) }
            let dim = inDim(header, "(double_blocks|single_blocks|single_transformer_blocks)_\\d+_")
            if [3072, 12288, 15360].contains(dim ?? 3072) {
                return ("flux1", t("FLUX.1-LoRA (läuft auch an Chroma, dort nicht immer gleich gut)",
                                   "FLUX.1 LoRA (also runs on Chroma, not always equally well)"))
            }
        }
        // Qwen-Image: transformer_blocks.N.attn.(add_)k_proj / img_mlp, 60 Blöcke, Breite 3072
        if has("transformer_blocks_\\d+_(attn_(add_)?[kqv]_proj|attn_to_[kqv]|img_mlp|txt_mlp)") {
            let dim = inDim(header, "transformer_blocks_\\d+_attn_")
            if [3072].contains(dim ?? 3072) && !has("single_transformer_blocks") {
                // Nur auf dem Mac: Eine FLUX.2-Klein-LoRA nur auf den Doppelblöcken (Diffusers-Namen) sieht aus wie
                // eine Qwen-LoRA; Qwen-Image hat aber 60 Blöcke, FLUX.2 Klein höchstens 8, und kein img_mlp/txt_mlp
                let blocks = numbers(joined, "transformer_blocks_(\\d+)_")
                if (blocks.max() ?? 99) < 8 && !has("img_mlp|txt_mlp") { return flux2Size(header, joined) }
                return ("qwenimage", t("Qwen-Image-LoRA", "Qwen-Image LoRA"))
            }
        }
        return (nil, t("LoRA für eine Architektur, die NVAI-open nicht kennt.",
                       "LoRA for an architecture NVAI-open does not know."))
    }

    /// FLUX.2 Klein: 4B oder 9B nach der Breite der Aufmerksamkeit (3072 bzw. 4096), sonst nach den Blocknummern.
    private static func flux2Size(_ header: [String: JSONValue], _ joined: String) -> (base: String?, why: String) {
        let width = inDim(header, "(transformer_blocks|double_blocks|single_transformer_blocks|single_blocks)_\\d+_"
                          + "(attn_to_[qkv]_|attn_add_[qkv]_proj|attn_to_qkv_mlp_proj|img_attn_qkv|txt_attn_qkv|linear1)")
        let doubles = numbers(joined, "(?:double_blocks|(?<!single_)transformer_blocks)_(\\d+)_")
        let singles = numbers(joined, "single_(?:transformer_)?blocks_(\\d+)_")
        let small = (doubles.max() ?? 0) <= 4 && (singles.max() ?? 0) <= 19
        if width == 3072 || (width == nil && small) {
            return ("flux2-klein-4b", t("FLUX.2-Klein-4B-LoRA", "FLUX.2 Klein 4B LoRA"))
        }
        if width == 4096 || width == nil {
            return ("flux2-klein-9b", t("FLUX.2-Klein-9B-LoRA", "FLUX.2 Klein 9B LoRA"))
        }
        return (nil, t("FLUX.2-LoRA unbekannter Größe (Breite \(width!)).", "FLUX.2 LoRA of unknown size (width \(width!))."))
    }

    /// Lädt flux-2-swift-mlx diese Datei? Es liest die Namen lora_A/lora_B (PEFT, Diffusers, ai-toolkit); das kohya-
    /// Format (lora_down/lora_up) überginge es still, die LoRA wirkte dann gar nicht.
    static func macLoadable(_ header: [String: JSONValue]) -> Bool {
        header.keys.contains { $0.hasSuffix(".lora_A.weight") } && header.keys.contains { $0.hasSuffix(".lora_B.weight") }
    }

    /// Trigger-Vorschlag aus den Metadaten: ausdrücklich gesetzt (ModelSpec), sonst die häufigsten Trainings-Tags
    /// (kohya, ai-toolkit).
    static func triggerFromMetadata(_ header: [String: JSONValue]) -> String {
        let meta = header["__metadata__"]?.objectValue ?? [:]
        let phrase = (meta["modelspec.trigger_phrase"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrase.isEmpty { return String(phrase.prefix(300)) }
        guard let raw = meta["ss_tag_frequency"]?.stringValue, let sets = JSON.parse(Data(raw.utf8))?.objectValue else {
            return ""
        }
        var freq: [String: Int] = [:]
        for (_, tags) in sets {
            for (tag, n) in tags.objectValue ?? [:] {
                let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                freq[tag, default: 0] += n.intValue ?? 0
            }
        }
        // Gleich häufige in der Reihenfolge der Datei, wie unter Windows (Python-Wörterbücher behalten sie)
        func position(_ tag: String) -> Int {
            raw.range(of: "\"\(tag)\"").map { raw.distance(from: raw.startIndex, to: $0.lowerBound) } ?? Int.max
        }
        let top = freq.sorted { ($0.value, -position($0.key)) > ($1.value, -position($1.key)) }.prefix(3)
        return top.map(\.key).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static let hfHints: [(String, String)] = [
        ("stable-diffusion-xl", "sdxl"), ("sdxl", "sdxl"), ("pony", "sdxl"), ("illustrious", "sdxl"),
        ("noobai", "sdxl"), ("stable-diffusion-v1-5", "sd15"), ("qwen-image", "qwenimage"),
        ("z-image", "zimage"), ("flux.1", "flux1"), ("chroma", "flux1"), ("flux.2-klein", "flux2"),
        ("wan2.1-t2v-1.3b", "wan-1.3b"), ("wan2.2-ti2v-5b", "wan-5b"), ("wan2.1", "wan-14b"),
        ("wan2.2", "wan-14b"), ("ltx-2", "ltx2"), ("ltx-video", "ltxv"),
    ]
    private static let metaHints: [(String, String)] = [("flux1", "flux1"), ("qwen_image", "qwenimage"), ("sd_v1", "sd15"),
                                                         ("flux2_klein", "flux2"), ("flux.2", "flux2")]

    /// Vorschlag aus den Metadaten (kohya ss_base_model_version, ModelSpec architecture), wenn der Kopf nichts
    /// Eindeutiges zeigt; der Nutzer bestätigt ihn. FLUX.2 Klein mit „9b“ im Namen ist die 9B-Fassung.
    static func metadataBaseHint(_ header: [String: JSONValue]) -> String? {
        let meta = header["__metadata__"]?.objectValue ?? [:]
        for field in ["modelspec.architecture", "ss_base_model_version"] {
            let value = (meta[field]?.stringValue ?? "").lowercased()
            guard !value.isEmpty else { continue }
            let hit = hfHints.first { value.contains($0.0) }?.1 ?? metaHints.first { value.contains($0.0) }?.1
            if hit == "flux2" { return value.contains("9b") ? "flux2-klein-9b" : "flux2-klein-4b" }
            if let hit { return hit }
        }
        return nil
    }

    /// Wan 2.2 A14B: LoRAs kommen als Paar für den High- und Low-Noise-Experten (nach dem Dateinamen).
    static func expertOf(_ name: String) -> String? {
        let low = name.lowercased()
        if contains(low, "high[_\\-]?noise|(^|[_\\-])high([_\\-.]|$)|[_\\-]h[_\\-]e\\d") { return "high" }
        if contains(low, "low[_\\-]?noise|(^|[_\\-])low([_\\-.]|$)|[_\\-]l[_\\-]e\\d") { return "low" }
        return nil
    }

    /// Was eine Datei ist, die keine LoRA ist (kurz, ohne die Workflows der Windows-Fassung).
    static func classify(_ keys: [String]) -> String {
        func starts(_ p: String) -> Bool { keys.contains { $0.hasPrefix(p) } }
        func has(_ name: String) -> Bool {
            ["model.diffusion_model.", "diffusion_model.", "model.", ""].contains { p in
                name.hasSuffix(".") ? starts(p + name) : keys.contains(p + name)
            }
        }
        let unet = starts("model.diffusion_model.")
        let vae = starts("first_stage_model.")
        if starts("conditioner.embedders.1.") && unet {
            return vae ? t("SDXL-Checkpoint (Grundmodell, keine LoRA).", "SDXL checkpoint (base model, not a LoRA).")
                       : t("Nur die SDXL-UNet.", "SDXL UNet only.")
        }
        if starts("cond_stage_model.transformer.text_model.") && unet && vae {
            return t("Stable-Diffusion-1.5-Checkpoint (Grundmodell, keine LoRA).", "Stable Diffusion 1.5 checkpoint (base model, not a LoRA).")
        }
        if starts("cond_stage_model.model.") { return t("Stable-Diffusion-2-Checkpoint.", "Stable Diffusion 2 checkpoint.") }
        let families: [(String, [String])] = [
            ("Qwen-Image 2.1", ["txt_in.text_norm.weight", "modulation.1.weight", "img_in.weight"]),
            ("Qwen-Image", ["txt_norm.weight", "img_in.weight"]),
            ("FLUX.3", ["content_mode_blocks.image.0.attn_out.weight"]),
            ("FLUX.2", ["double_stream_modulation_img.lin.weight"]),
            ("Chroma", ["distilled_guidance_layer."]),
            ("FLUX.1", ["double_blocks.", "img_in.weight"]),
            ("Wan", ["head.modulation"]),
            ("LTX-Video", ["adaln_single.emb.timestep_embedder.linear_1.bias"]),
            ("Z-Image / Lumina 2", ["cap_embedder.1.weight"]),
        ]
        if let family = families.first(where: { $0.1.allSatisfy(has) })?.0 {
            return t("Diffusionsmodell von \(family) (Grundmodell, keine LoRA).", "\(family) diffusion model (base model, not a LoRA).")
        }
        if starts("controlnet_blocks.") || starts("input_hint_block.") || starts("control_model.") {
            return t("ControlNet.", "ControlNet.")
        }
        if starts("decoder.") && (starts("encoder.") || starts("decoder.conv_in") || starts("decoder.conv1")) {
            return t("VAE, Baustein eines Modells.", "VAE, a model component.")
        }
        if starts("encoder.block.0.layer.0.SelfAttention.") || starts("text_model.encoder.") || starts("model.layers.")
            || starts("language_model.") {
            return t("Text-Encoder, Baustein eines Modells.", "Text encoder, a model component.")
        }
        return t("Unbekannte Architektur.", "Unknown architecture.")
    }

    /// Was eine Datei ist und wozu sie passt, aus ihrem Kopf (POST /api/loras/inspect, Felder wie `LoraCheck`).
    static func inspect(_ header: [String: JSONValue], fileName: String = "") -> LoRACheck {
        let keys = header.keys.filter { $0 != "__metadata__" }
        var out = LoRACheck(name: stem(fileName))
        guard isLoRA(keys) else {
            out.verdict = t("Keine LoRA. Die Datei ist: \(classify(keys))", "Not a LoRA. The file is: \(classify(keys))")
            return out
        }
        let (base, why) = detect(header)
        let targets = Self.targets(base)
        let hint = base == nil ? metadataBaseHint(header) : nil
        var ok = base != nil && !targets.isEmpty
        var verdict: String
        if let base, !targets.isEmpty {
            verdict = t("\(sentence(why)) Läuft mit: \(targets.joined(separator: ", ")).",
                        "\(sentence(why)) Runs with: \(targets.joined(separator: ", ")).")
            if macBases.contains(base) && !macLoadable(header) {
                ok = false
                verdict = t("\(sentence(why)) Sie liegt im kohya-Format (lora_down/lora_up); das lädt NVAI-open für Mac nicht.",
                            "\(sentence(why)) It is in kohya format (lora_down/lora_up), which NVAI-open for Mac does not load.")
            }
        } else if base != nil {
            verdict = t("\(sentence(why)) Im Katalog gibt es dafür kein Modell.",
                        "\(sentence(why)) There is no model for it in the catalog.")
        } else if let hint {
            verdict = t("\(sentence(why)) Laut den Metadaten der Datei vermutlich \(label(hint)): bitte bestätigen.",
                        "\(sentence(why)) According to the file's metadata probably \(label(hint)): please confirm.")
        } else {
            verdict = t("\(sentence(why)) Bitte von Hand zuordnen.", "\(sentence(why)) Please assign it by hand.")
        }
        out.ok = ok
        out.lora = true
        out.family = base
        out.suggested = base ?? hint
        out.catalog = targets
        out.verdict = verdict
        out.trigger = triggerFromMetadata(header)
        out.expert = expertOf(stem(fileName))
        return out
    }
}

/// Prüfung einer LoRA-Datei vor dem Hinzufügen, Felder wie `LoraCheck` unter Windows.
struct LoRACheck: Sendable, Equatable {
    /// LoRA mit erkannter Basis, für die es ein Modell gibt (und die der Mac laden kann)
    var ok = false
    /// überhaupt eine LoRA
    var lora = false
    /// am Kopf erkannte Basis; nil = nicht erkannt
    var family: String?
    /// erkannte Basis oder Vorschlag aus den Metadaten
    var suggested: String?
    /// Modelle, die LoRAs dieser Basis nehmen
    var catalog: [String] = []
    var verdict = ""
    /// Trigger-Wörter aus den Metadaten
    var trigger = ""
    var expert: String?
    /// Vorschlag für den Namen: der Dateiname ohne Endung
    var name = ""

    var json: [String: Any] {
        ["ok": ok, "lora": lora, "family": family ?? NSNull(), "suggested": suggested ?? NSNull(), "catalog": catalog,
         "verdict": verdict, "trigger": trigger, "expert": expert ?? NSNull(), "name": name]
    }
}

/// SHA-256 und Länge, während eine Datei blockweise geschrieben wird (Hochladen und Kopieren aus dem Dateidialog).
final class HashingFileWriter {
    let url: URL
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var size: Int64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw APIError(500, t("Datei nicht schreibbar: \(url.lastPathComponent)", "Cannot write file: \(url.lastPathComponent)"))
        }
        self.url = url
        handle = h
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        size += Int64(data.count)
    }

    /// Schließt die Datei; gibt die Prüfsumme als Hex-Text zurück.
    func finish() -> String {
        try? handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
