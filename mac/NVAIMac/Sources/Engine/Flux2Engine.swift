import Foundation
import CoreGraphics
import Flux2Core
import Flux2Chains
import FluxTextEncoders

/// Was die Engine rechnen soll.
enum EngineMode: Sendable {
    case text
    /// Referenzbilder als Bedingung (FLUX.2: 1 bis 3); das Bild entsteht neu.
    case references([CGImage])
    /// Klassisches Bild-zu-Bild: startet beim Ausgangsbild, `strength` wie NVAI-opens `denoise`.
    case imageToImage(CGImage, strength: Float, references: [CGImage])
    /// Füllen: weiß in der Maske wird neu gerechnet, schwarz bleibt bitgleich.
    case inpaint(CGImage, mask: CGImage, references: [CGImage])

    var name: String {
        switch self {
        case .text: return "txt2img"
        case .references: return "references"
        case .imageToImage: return "img2img"
        case .inpaint: return "inpaint"
        }
    }
}

struct EngineJob: Sendable {
    var mode: EngineMode
    var prompt: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Float
    var seed: UInt64
}

/// FLUX.2 Klein über flux-2-swift-mlx. Hält die Pipeline zwischen Aufträgen geladen;
/// den Text-Encoder entlädt das Paket nach jedem Bild selbst.
///
/// Abbrechen: Die lokale Kopie des Pakets prüft nach jedem Rechenschritt auf Abbruch des Tasks
/// (Packages/flux-2-swift-mlx/NVAI-OPEN-CHANGES.md); die Warteschlange bricht dafür ihren Task ab.
actor Flux2Engine {
    static let shared = Flux2Engine()

    private var pipeline: Flux2Pipeline?
    private var loadedModelID: String?

    /// Beide Register zeigen auf denselben Ordner, wie in der CLI des Pakets.
    nonisolated static func configureModelsDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        ModelRegistry.customModelsDirectory = url
        TextEncoderModelDownloader.customModelsDirectory = url
        TextEncoderModelDownloader.reconfigureHubApi()
    }

    func currentModelID() -> String? { loadedModelID }

    /// Lädt fehlende Dateien von Hugging Face und das Modell in den Speicher.
    func load(_ model: CatalogModel, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if loadedModelID == model.id, pipeline != nil { return }
        await unload()
        let p = Flux2Pipeline(
            model: .klein4B,
            quantization: Flux2QuantizationConfig(textEncoder: model.encoder, transformer: model.transformer),
            vaeVariant: .smallDecoder   // Apache-2.0; die Standard-VAE ist nur nicht-kommerziell
        )
        if SystemInfo.memoryGB <= 16 {
            p.memoryProfile = .conservative
        }
        try await p.loadModels(progressCallback: progress)
        pipeline = p
        loadedModelID = model.id
    }

    func unload() async {
        if let p = pipeline {
            await p.clearAll()
        }
        pipeline = nil
        loadedModelID = nil
    }

    /// „Prompt ausbauen“: Qwen3-4B, der Text-Encoder von FLUX.2 Klein, schreibt aus ein paar Worten
    /// eine volle Bildbeschreibung (BFLs Systemprompt für Text zu Bild, ohne Denkmodus). Braucht keinen
    /// eigenen Download. Auf Macs bis 16 GB wird das Bildmodell vorher entladen.
    func expand(_ prompt: String, model: CatalogModel) async throws -> String {
        if SystemInfo.memoryGB <= 16 { await unload() }
        let encoder = KleinTextEncoder(variant: .klein4B, quantization: model.encoder)
        try await encoder.load()
        defer { encoder.unload() }
        var text = try encoder.upsamplePrompt(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        // Qwen3 setzt die ganze Beschreibung gern in Anführungszeichen (gemessen auf dem M1).
        // Nur dieses äußere Paar entfernen; Schrift im Bild steht laut Systemprompt in eigenen.
        if text.count > 2, text.hasPrefix("\""), text.hasSuffix("\""), !text.dropFirst().dropLast().contains("\"") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    func generate(_ job: EngineJob, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> CGImage {
        guard let p = pipeline else { throw APIError(500, t("Kein Modell geladen.", "No model loaded.")) }
        // FLUX.2 rechnet in Vielfachen von 32 (VAE 8 × Patch 2, gepackt). Das Ergebnis bringt
        // die Warteschlange danach auf die bestellte Größe.
        let w = max(256, (job.width / 32) * 32)
        let h = max(256, (job.height / 32) * 32)
        switch job.mode {
        case .text:
            return try await p.generateWithResult(
                mode: .textToImage, prompt: job.prompt, height: h, width: w, steps: job.steps,
                guidance: job.guidance, seed: job.seed, upsamplePrompt: false, checkpointInterval: nil,
                onProgress: onProgress, onCheckpoint: nil
            ).image
        case .references(let refs):
            return try await p.generateWithResult(
                mode: .imageToImage(images: Array(refs.prefix(3))), prompt: job.prompt, height: h, width: w,
                steps: job.steps, guidance: job.guidance, seed: job.seed, upsamplePrompt: false,
                checkpointInterval: nil, onProgress: onProgress, onCheckpoint: nil
            ).image
        case .imageToImage(let image, let strength, let refs):
            let initLatents = try await p.encodeImageToPackedSequence(image, targetHeight: h, targetWidth: w)
            let mode: Flux2GenerationMode = refs.isEmpty ? .textToImage : .imageToImage(images: Array(refs.prefix(3)))
            return try await p.generateWithResult(
                mode: mode, prompt: job.prompt, height: h, width: w, steps: job.steps,
                guidance: job.guidance, seed: job.seed, upsamplePrompt: false, checkpointInterval: nil,
                initLatents: initLatents, strength: max(0.05, min(1, strength)),
                onProgress: onProgress, onCheckpoint: nil
            ).image
        case .inpaint(let image, let mask, let refs):
            let chain = Flux2MaskedInpaintingChain(
                pipeline: p, prompt: job.prompt, image: image, mask: mask,
                maskConvention: .grayscaleWhiteInpaint,
                referenceImages: refs.isEmpty ? nil : Array(refs.prefix(3)),
                steps: job.steps, guidance: job.guidance, seed: job.seed, strength: 1.0,
                compositeOnOriginal: true,   // außerhalb der Maske bitgleich
                maxPixels: max(w * h, 256 * 256),
                onProgress: onProgress
            )
            return try await chain.run().image
        }
    }
}
