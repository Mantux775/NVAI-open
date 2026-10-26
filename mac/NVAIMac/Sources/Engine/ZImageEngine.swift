import Foundation
import CoreGraphics
import MLX
import Tokenizers
import ZImage

/// Z-Image Turbo über MLX (`ZImageCatalog`). Auf Macs bis 16 GB rechnet erst der Text-Encoder (Qwen3-4B, 2,3 GB in
/// 4 Bit) und wird entladen, bevor der DiT (3,7 GB) lädt; vor dem Dekodieren geht auch der DiT. Darüber bleibt alles
/// geladen. Der DiT rechnet in bf16: float16 gab am M1 ein schwarzes Bild (Überlauf), obwohl es 30 % schneller war.
actor ZImageEngine {
    static let shared = ZImageEngine()

    private var loadedID: String?
    private var tokenizer: Tokenizer?
    private var encoder: Qwen3HiddenStateEncoder?
    private var transformer: ZImageTransformer2DModel?
    private var vae: AutoencoderKL?

    func currentModelID() -> String? { loadedID }

    func unload() {
        tokenizer = nil
        encoder = nil
        transformer = nil
        vae = nil
        loadedID = nil
        Memory.clearCache()
    }

    private var small: Bool { SystemInfo.memoryGB <= 16 }

    /// Prompt-Merkmale (hidden_states[-2] von Qwen3-4B, Chat-Vorlage wie im Port).
    private func encode(_ prompt: String, model: ZImageModel) async throws -> MLXArray {
        let dir = model.directory
        if tokenizer == nil {
            tokenizer = try await AutoTokenizer.from(modelFolder: dir.appendingPathComponent("tokenizer"))
        }
        if encoder == nil {
            encoder = try ZImageWeights.loadMFluxTextEncoder(directory: dir.appendingPathComponent("text_encoder"))
        }
        let textEncoder = ZImageTextEncoder(encoder: encoder!, tokenizer: tokenizer!)
        let features = textEncoder.encode(prompt)
        eval(features)
        if small {
            encoder = nil
            Memory.clearCache()
        }
        return features
    }

    private func loadImageModel(_ model: ZImageModel) throws {
        let dir = model.directory
        let precise = dir.appendingPathComponent(ZImageModel.preciseFile)
        if transformer == nil {
            transformer = try ZImageWeights.loadMFluxTransformer(
                directory: dir.appendingPathComponent("transformer"),
                precise: FileManager.default.fileExists(atPath: precise.path) ? precise : nil)
        }
        if vae == nil {
            vae = try ZImageWeights.loadMFluxVAE(directory: dir.appendingPathComponent("vae"))
        }
        loadedID = model.id
    }

    /// Größte Kachel beim Dekodieren (Latent-Pixel, × 8 im Bild). Der fp32-VAE braucht bei 1024² rund 12 GB;
    /// 72² Latents (576² Pixel) brauchen ein Drittel davon und passen neben das System eines 8-GB-Macs.
    private var decodeTile: Int { SystemInfo.memoryGB <= 8 ? 72 : SystemInfo.memoryGB <= 16 ? 104 : 128 }

    /// Ein Bild; `onStep(schritt, alle)`, danach `onDecode(kachel, alle)`. Abbrechen über den Task (der Port prüft
    /// nach jedem Schritt).
    func generate(model: ZImageModel, prompt: String, width: Int, height: Int, steps: Int, seed: UInt64,
                  onStep: @escaping @Sendable (Int, Int) -> Void,
                  onDecode: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CGImage {
        guard model.installed else {
            throw APIError(409, t("„\(model.name)“ ist nicht geladen.", "\"\(model.name)\" is not downloaded."))
        }
        // Auf kleinen Macs: DiT freigeben, solange der Text-Encoder rechnet.
        if small {
            transformer = nil
            vae = nil
            Memory.clearCache()
        }
        let features = try await encode(prompt, model: model)
        MemoryLog.line("Z-Image text encoded")
        try Task.checkCancellation()
        try loadImageModel(model)
        MemoryLog.line("Z-Image DiT and VAE loaded")
        // Kein lokales `let transformer`: es hielte den DiT über das Freigeben unten hinaus fest.
        guard let vae, self.transformer != nil else {
            throw APIError(500, t("Z-Image ließ sich nicht laden.", "Could not load Z-Image."))
        }
        let w = max(256, width / 16 * 16), h = max(256, height / 16 * 16)
        let scheduler = FlowMatchEulerDiscreteScheduler(numTrainTimesteps: 1000, shift: 3.0, useDynamicShifting: false)
        let result = ZImagePipeline.generate(
            transformer: self.transformer!, vae: vae, textEncoder: nil, scheduler: scheduler, prompt: prompt,
            height: h, width: w, numInferenceSteps: steps, guidanceScale: 0, seed: seed, decodeImage: false,
            precomputedPromptEmbeds: features, onStep: { step, total in onStep(step, total) })
        MemoryLog.line("Z-Image denoised")
        try Task.checkCancellation()
        // Auf kleinen Macs den DiT vor dem Dekodieren freigeben (3,5 GB); er lädt beim nächsten Bild ohnehin neu,
        // weil dann erst wieder der Text-Encoder rechnet.
        if small {
            self.transformer = nil
            Memory.clearCache()
        }
        let z = result.latents.asType(.float32) / vae.scalingFactor + vae.shiftFactor
        let image = vae.decodeTiled(z, maxTile: decodeTile, overlap: 16) { done, total in onDecode(done, total) }
        eval(image)
        MemoryLog.line("Z-Image decoded")
        // [-1, 1] NCHW → RGBA8
        let rgb = MLX.clip(image[0] / 2 + 0.5, min: 0, max: 1).transposed(1, 2, 0) * 255 + 0.5
        let u8 = rgb.asType(.uint8)
        eval(u8)
        let px = u8.asArray(UInt8.self)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = px[i * 3]
            rgba[i * 4 + 1] = px[i * 3 + 1]
            rgba[i * 4 + 2] = px[i * 3 + 2]
        }
        Memory.clearCache()
        guard let cg = Outpaint.makeImage(rgba, width: w, height: h) else {
            throw APIError(500, t("Bild ließ sich nicht anlegen.", "Could not create the image."))
        }
        return cg
    }
}
