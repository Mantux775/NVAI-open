import CoreGraphics
import Foundation
import LTXV
import MLX
import Tokenizers

/// LTX-Video 2B über MLX (`VideoCatalog`). Auf Macs bis 16 GB laden Bild-Encoder (nur mit Startbild, 0,9 GB in
/// float32), T5 (2,8 GB), Transformer (3,7 GB) und Decoder nacheinander; darüber bleiben sie geladen. Der Decoder
/// rechnet in float32 und die letzte Stufe in Kacheln (exakt: gleiches Ergebnis wie in einem Stück, siehe
/// `LTXVideoDecoder.decode(tile:)`).
actor VideoEngine {
    static let shared = VideoEngine()

    private var tokenizer: Tokenizer?
    private var t5: T5Encoder?
    private var transformer: LTXTransformer?
    private var decoder: LTXVideoDecoder?
    private var encoder: LTXImageEncoder?

    private var small: Bool { SystemInfo.memoryGB <= 16 }

    /// Kachel der letzten Decoder-Stufe in Pixeln bei 1/8 der Auflösung (32 → 256 px), 0 = ein Stück.
    private var decodeTile: Int { SystemInfo.memoryGB <= 8 ? 32 : SystemInfo.memoryGB <= 16 ? 64 : 0 }

    func unload() {
        tokenizer = nil
        t5 = nil
        transformer = nil
        decoder = nil
        encoder = nil
        Memory.clearCache()
    }

    struct Result {
        let url: URL
        let frames: Int
        let timings: [String: Double]
    }

    /// Ein Clip als MP4 im Temp-Ordner. `onStep(schritt, alle)` beim Entrauschen, `onDecode(kachel, alle)` danach.
    /// `startImage`: erstes Bild des Videos (Bild zu Video); `preparation` und `imageNoiseScale` nur für Prüfläufe.
    func generate(prompt: String, width: Int, height: Int, frames: Int, fps: Int = VideoCatalog.fps, seed: UInt64,
                  startImage: CGImage? = nil, preparation: VideoStartImage.Preparation = .none,
                  imageNoiseScale: Float = LTXPipeline.imageNoiseScale,
                  onStep: @escaping @Sendable (Int, Int) -> Void,
                  onDecode: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        guard VideoCatalog.installed else {
            throw APIError(409, t("„\(VideoCatalog.name)“ ist nicht geladen.", "\"\(VideoCatalog.name)\" is not downloaded."))
        }
        var timings: [String: Double] = [:]
        if small {
            transformer = nil
            decoder = nil
            Memory.clearCache()
        }
        var t0 = Date()
        // 0. Startbild: zuschneiden, skalieren, kodieren (rund 1 s mit Laden des Encoders)
        var startLatent: MLXArray?
        if let startImage {
            guard VideoCatalog.encoderInstalled else {
                throw APIError(409, t("Das Startbild braucht den Bild-Encoder von LTX-Video. Unter „Modelle“ nachrüsten.",
                                      "A start image needs LTX-Video's image encoder. Add it under \"Models\"."))
            }
            let pixels = try VideoStartImage.prepare(startImage, width: width, height: height, preparation: preparation)
            if encoder == nil {
                encoder = try LTXWeights.loadImageEncoder(file: VideoCatalog.encoderFile, config: VideoCatalog.vaeConfig)
            }
            startLatent = encoder!.encode(pixels)
            eval(startLatent!)
            if small {
                encoder = nil
                Memory.clearCache()
            }
            timings["image"] = Date().timeIntervalSince(t0)
            MemoryLog.line("LTX-Video start image encoded")
            t0 = Date()
        }
        // 1. Text
        if tokenizer == nil { tokenizer = try await AutoTokenizer.from(modelFolder: VideoCatalog.tokenizerDirectory) }
        if t5 == nil {
            t5 = try LTXWeights.loadT5(directory: VideoCatalog.t5Directory, relativeBias: VideoCatalog.t5BiasFile)
        }
        let context = T5TextEncoder(encoder: t5!, tokenizer: tokenizer!).encode(prompt)
        if small {
            t5 = nil
            Memory.clearCache()
        }
        timings["text"] = Date().timeIntervalSince(t0)
        MemoryLog.line("LTX-Video text encoded")
        try Task.checkCancellation()

        // 2. Entrauschen
        t0 = Date()
        if transformer == nil { transformer = try LTXWeights.loadTransformer(file: VideoCatalog.ditFile) }
        timings["load_transformer"] = Date().timeIntervalSince(t0)
        MemoryLog.line("LTX-Video transformer loaded")
        t0 = Date()
        let latents = LTXPipeline.denoise(
            transformer: transformer!, context: context, frames: frames, height: height, width: width,
            frameRate: Float(fps), seed: seed, startImage: startLatent, imageNoiseScale: imageNoiseScale, onStep: onStep)
        timings["denoise"] = Date().timeIntervalSince(t0)
        MemoryLog.line("LTX-Video denoised")
        try Task.checkCancellation()
        if small {
            transformer = nil
            Memory.clearCache()
        }

        // 3. Dekodieren
        t0 = Date()
        if decoder == nil { decoder = try LTXWeights.loadDecoder(file: VideoCatalog.decoderFile) }
        let noise = LTXPipeline.decodeNoise(like: latents, seed: seed)
        let video = decoder!.decode(latents, noise: noise, dtype: .float32, tile: decodeTile) { done, total in
            onDecode(done, total)
        }
        let rgb = LTXPipeline.frames(video)
        timings["decode"] = Date().timeIntervalSince(t0)
        MemoryLog.line("LTX-Video decoded")
        if small {
            decoder = nil
            Memory.clearCache()
        }

        // 4. MP4
        t0 = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvai-ltxv-\(UUID().uuidString).mp4")
        try await VideoWriter.writeMP4(frames: rgb, width: width, height: height, fps: fps, to: url)
        timings["mp4"] = Date().timeIntervalSince(t0)
        return Result(url: url, frames: rgb.count, timings: timings)
    }
}
