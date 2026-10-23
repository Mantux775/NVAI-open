import Foundation
import Flux2Core
import FluxTextEncoders

/// Ein Modell, das NV-AI für Mac anbietet. Felder wie `ModelInfo` im NV-AI-Vertrag.
/// Texte zweisprachig: die Eigenschaften liefern die aktuelle Sprache (App bzw. Accept-Language).
struct CatalogModel: Identifiable, Sendable, Equatable {
    let id: String
    let nameDE: String
    let nameEN: String
    let workflow: String
    let transformer: TransformerQuantization
    let encoder: MistralQuantization
    /// Download in GB: Transformer + Text-Encoder + VAE (Small Decoder).
    let downloadGB: Double
    let minRAMGB: Int
    let recommendedRAMGB: Int
    let bestForDE: String
    let bestForEN: String
    let descriptionDE: String
    let descriptionEN: String
    let prosDE: [String]
    let prosEN: [String]
    let consDE: [String]
    let consEN: [String]

    var name: String { t(nameDE, nameEN) }
    var bestFor: String { t(bestForDE, bestForEN) }
    var description: String { t(descriptionDE, descriptionEN) }
    var pros: [String] { Lang.current == .de ? prosDE : prosEN }
    var cons: [String] { Lang.current == .de ? consDE : consEN }
}

enum ModelCatalog {
    static let flux2Workflow = "flux2_klein"

    /// FLUX.2 Klein 4B (Black Forest Labs, Apache-2.0), über MLX gerechnet.
    /// Größen laut Hugging Face, gemessen beim Laden auf dem Mac mini am 19.10.2026.
    static let all: [CatalogModel] = [
        CatalogModel(
            id: "flux2-klein-4b", nameDE: "FLUX.2 Klein 4B (4 Bit)", nameEN: "FLUX.2 Klein 4B (4-bit)",
            workflow: flux2Workflow, transformer: .int4, encoder: .mlx4bit, downloadGB: 10.6,
            minRAMGB: 8, recommendedRAMGB: 16,
            bestForDE: "Macs mit 8 bis 16 GB: Generieren, Überarbeiten, Füllen",
            bestForEN: "Macs with 8 to 16 GB: generate, refine, fill",
            descriptionDE: "FLUX.2 Klein 4B von Black Forest Labs, Apache-2.0. Der Transformer wird beim "
                + "Laden auf 4 Bit gebracht, der Text-Encoder Qwen3-4B läuft in 4 Bit. Vier Schritte reichen "
                + "(destilliert). Kann Referenzbilder (bis 3), Bild-zu-Bild und Füllen mit Maske.",
            descriptionEN: "FLUX.2 Klein 4B by Black Forest Labs, Apache-2.0. The transformer is quantized to "
                + "4-bit while loading, the Qwen3-4B text encoder runs in 4-bit. Four steps are enough "
                + "(distilled). Supports reference images (up to 3), image-to-image and masked fills.",
            prosDE: ["Läuft schon auf 8 GB (512 × 512 in 38 s auf einem M1)", "Füllen mit Maske", "Apache-2.0"],
            prosEN: ["Runs on 8 GB (512 × 512 in 38 s on an M1)", "Masked fills", "Apache-2.0"],
            consDE: ["Lädt die volle Fassung (7,75 GB) und quantisiert beim Start",
                     "Schrift nicht immer buchstabengenau"],
            consEN: ["Downloads the full weights (7.75 GB) and quantizes on load",
                     "Lettering is not always exact"]),
        CatalogModel(
            id: "flux2-klein-4b-q8", nameDE: "FLUX.2 Klein 4B (8 Bit)", nameEN: "FLUX.2 Klein 4B (8-bit)",
            workflow: flux2Workflow, transformer: .qint8, encoder: .mlx8bit, downloadGB: 8.8,
            minRAMGB: 24, recommendedRAMGB: 24,
            bestForDE: "Macs ab 24 GB: beste Qualität dieser Fassung",
            bestForEN: "Macs with 24 GB or more: best quality of this model",
            descriptionDE: "Dasselbe Modell mit 8-Bit-Transformer (vorquantisiert, Community-Fassung "
                + "aydin99/FLUX.2-klein-4B-int8) und 8-Bit-Text-Encoder. Genauer als die 4-Bit-Fassung.",
            descriptionEN: "The same model with an 8-bit transformer (pre-quantized community build "
                + "aydin99/FLUX.2-klein-4B-int8) and an 8-bit text encoder. More accurate than 4-bit.",
            prosDE: ["Höhere Genauigkeit als 4 Bit", "Kleinerer Download, nichts wird beim Start umgerechnet"],
            prosEN: ["More accurate than 4-bit", "Smaller download, no conversion on load"],
            consDE: ["Ab 24 GB Arbeitsspeicher"],
            consEN: ["Needs 24 GB of memory or more"]),
    ]

    static func model(_ id: String?) -> CatalogModel? { all.first { $0.id == id } }

    /// Nach Arbeitsspeicher: ab 24 GB die 8-Bit-Fassung.
    static var recommended: CatalogModel { SystemInfo.memoryGB >= 24 ? all[1] : all[0] }

    static var activeModel: CatalogModel {
        if let chosen = model(Settings.activeModelID) { return chosen }
        return all.first { status($0).installed } ?? recommended
    }

    // MARK: Status

    struct Status: Sendable {
        var transformer: Bool
        var encoder: Bool
        var vae: Bool
        var installed: Bool { transformer && encoder && vae }
        var partial: Bool { (transformer || encoder || vae) && !installed }
    }

    static func transformerVariant(_ m: CatalogModel) -> ModelRegistry.TransformerVariant {
        ModelRegistry.TransformerVariant.variant(for: .klein4B, quantization: m.transformer)
    }

    static func status(_ m: CatalogModel) -> Status {
        // Der Text-Encoder nimmt jede schon geladene Qwen3-4B-Fassung (8 Bit bevorzugt).
        let encoder = TextEncoderModelDownloader.isQwen3ModelDownloaded(variant: .qwen3_4B_4bit)
            || TextEncoderModelDownloader.isQwen3ModelDownloaded(variant: .qwen3_4B_8bit)
        return Status(transformer: ModelRegistry.isDownloaded(.transformer(transformerVariant(m))),
                      encoder: encoder,
                      vae: ModelRegistry.isDownloaded(.vae(.smallDecoder)))
    }

    static func fits(_ m: CatalogModel) -> String {
        let ram = SystemInfo.memoryGB
        if ram >= m.recommendedRAMGB { return "ja" }
        if ram >= m.minRAMGB { return "knapp" }
        return "nein"
    }

    static func warning(_ m: CatalogModel) -> String {
        let ram = SystemInfo.memoryGB
        if ram < m.minRAMGB {
            return t("Braucht mindestens \(m.minRAMGB) GB Arbeitsspeicher, dieser Mac hat \(ram) GB.",
                     "Needs at least \(m.minRAMGB) GB of memory; this Mac has \(ram) GB.")
        }
        if ram < m.recommendedRAMGB {
            return t("Läuft mit \(ram) GB, aber knapp: kleine Formate wählen und andere Programme schließen.",
                     "Runs with \(ram) GB, but tight: choose small sizes and quit other apps.")
        }
        return ""
    }

    // MARK: Vertrag

    static var flux2Sizes: [[String: Any]] {
        [
            ["label": t("1024 × 1024: Objekte, Icons", "1024 × 1024: objects, icons"), "w": 1024, "h": 1024],
            ["label": t("832 × 1216: Figuren", "832 × 1216: characters"), "w": 832, "h": 1216],
            ["label": t("1216 × 832: Fahrzeuge, Szenen", "1216 × 832: vehicles, scenes"), "w": 1216, "h": 832],
            ["label": t("1344 × 768: Panorama", "1344 × 768: panorama"), "w": 1344, "h": 768],
            ["label": t("768 × 1344: Hochformat schmal", "768 × 1344: tall portrait"), "w": 768, "h": 1344],
            ["label": t("512 × 512: schnell, für 8-GB-Macs", "512 × 512: fast, for 8 GB Macs"), "w": 512, "h": 512],
        ]
    }

    static var promptHint: String {
        t("Ganze Sätze: zuerst Stil und Medium, dann das Motiv mit Material, Farbe und Zustand, dann Licht und "
            + "Hintergrund. Konstruktion ausdrücklich nennen. Schrift in Anführungszeichen gelingt meist, aber "
            + "nicht immer buchstabengenau. Vier Schritte reichen.",
          "Full sentences: style and medium first, then the subject with material, color and condition, then "
            + "lighting and background. Spell out how things are built. Quoted lettering usually works, but not "
            + "always letter-perfect. Four steps are enough.")
    }

    static let placeholder = "Studio product photograph of a weathered wooden ammunition crate. Black stenciled "
        + "letters on the front read \"MUNITION 7,92\". Rope handles pass through drilled holes in the side "
        + "boards. Plain light grey background, soft even light."

    static func features(_ m: CatalogModel) -> [String: Any] {
        [
            "steps": 4, "cfg": 1.0,
            "negative_prompt": false, "default_negative": "",
            "upsampler": false, "references": 3, "bbox": false,
            "img2img": true, "mask": true, "hires": false, "text_rendering": false,
            // Erweitern per Maske (OutpaintMask.swift): "inpaint" = Maskenweg eines Modells, das aufs Füllen
            // trainiert ist – nahtlos genug, anders als Qwens "mask" unter Windows (keine Warnung im Add-on).
            "outpaint": "inpaint",
            "sizes": flux2Sizes, "prompt_hint": promptHint, "placeholder": placeholder,
        ]
    }

    static func files(_ m: CatalogModel, status st: Status) -> [[String: Any]] {
        let variant = transformerVariant(m)
        let qwenRepo = m.encoder == .mlx8bit ? "lmstudio-community/Qwen3-4B-MLX-8bit" : "lmstudio-community/Qwen3-4B-MLX-4bit"
        let models = ModelRegistry.modelsDirectory
        return [
            ["repo": variant.huggingFaceRepo,
             "file": m.transformer == .qint8 ? t("transformer (8 Bit)", "transformer (8-bit)") : "flux-2-klein-4b.safetensors",
             "target": "transformer", "installed": st.transformer,
             "local_path": ModelRegistry.localPath(for: .transformer(variant)).path,
             "size_gb": m.transformer == .qint8 ? 3.88 : 7.75],
            ["repo": qwenRepo, "file": "model.safetensors", "target": "text_encoder", "installed": st.encoder,
             "local_path": models.appendingPathComponent(qwenRepo).path,
             "size_gb": m.encoder == .mlx8bit ? 4.27 : 2.26],
            ["repo": "black-forest-labs/FLUX.2-small-decoder", "file": "small_decoder.safetensors",
             "target": "vae", "installed": st.vae,
             "local_path": ModelRegistry.localPath(for: .vae(.smallDecoder)).path, "size_gb": 0.61],
        ]
    }

    static func info(_ m: CatalogModel) -> [String: Any] {
        let st = status(m)
        return [
            "id": m.id, "name": m.name, "kind": "image", "family": "flux2", "workflow": m.workflow,
            "files": files(m, status: st),
            "size_gb": m.downloadGB, "vram_gb": m.minRAMGB,
            "license": "Apache-2.0", "commercial_ok": true,
            "warning": warning(m), "best_for": m.bestFor, "description": m.description,
            "pros": m.pros, "cons": m.cons,
            "installed": st.installed, "partially_installed": st.partial,
            "disk_gb": st.installed ? m.downloadGB : 0,
            "runnable": st.installed, "favorite": false, "fits_vram": fits(m),
            "features": features(m),
            "engine": "mlx",
        ].merging(ContentRating.apiFields(m.id)) { a, _ in a }
    }
}
