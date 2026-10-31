import CoreGraphics
import Foundation
import ImageIO
import LTXVideo
import MLX
import UniformTypeIdentifiers

/// LTX-2.3 und LTX-2.5 mit Ton über die lokale Kopie von ltx-video-swift-mlx (`Packages/ltx-video-swift-mlx`, MIT):
/// zweistufig destilliert (acht Schritte, dann Hochskalieren), Bild und Ton in einem Durchgang, Startbild möglich.
/// Für Macs ab 32 GB (2.3 in 4 Bit) bzw. 64 GB (2.5 in 8 Bit) und macOS 26.3 (Vorgabe des Pakets). Die Dateien legt
/// das Paket unter `Lightricks/LTX-2` im Modellordner ab; LTX-2.5 ist auf Hugging Face gesperrt (Token aus den
/// Einstellungen). Auf dem 8-GB-Testgerät von NVAI-open nicht lauffähig: übersetzt, aber nicht gemessen.
actor LTX2Engine {
    static let shared = LTX2Engine()

    private var pipeline: LTXPipeline?
    private var loadedID: String?

    static var directory: URL { Settings.modelsDirectory.appendingPathComponent("Lightricks/LTX-2") }
    static func marker(_ model: VideoModel) -> URL { directory.appendingPathComponent("\(model.id).complete") }

    /// Das Paket verlangt macOS 26.3 (README: „macOS 26.3+ (Tahoe)“).
    static var osSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 0))
    }

    static func checkOS() throws {
        guard osSupported else {
            throw APIError(422, t("LTX-2 braucht macOS 26.3 oder neuer.", "LTX-2 needs macOS 26.3 or later."))
        }
    }

    static func makePipeline(_ model: VideoModel) throws -> LTXPipeline {
        guard let raw = model.ltx2, let ltx = LTXModel(rawValue: raw) else {
            throw APIError(500, "LTX-2: \(model.id)")
        }
        LTXModelRegistry.customModelsDirectory = directory
        let quant: TransformerQuantization = model.bits == 8 ? .qint8 : .int4
        return LTXPipeline(model: ltx, quantization: LTXQuantizationConfig(transformer: quant), hfToken: Settings.hfToken)
    }

    /// Alles laden, was das Modell braucht (Transformer, Text-Encoder, VAE, Ton, Hochskalierer), ohne es in den
    /// Speicher zu holen; danach die Markierung.
    static func download(_ model: VideoModel, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try checkOS()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pipeline = try makePipeline(model)
        do {
            _ = try await pipeline.downloadModels { p in progress(p.progress * 0.9, p.message) }
            try await pipeline.downloadAudioModels { p in progress(0.9 + p.progress * 0.05, p.message) }
            progress(0.96, t("lädt den Hochskalierer", "downloading the upscaler"))
            _ = try await pipeline.downloadUpscalerWeights()
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if model.gated, text.contains("401") || text.contains("403") || text.lowercased().contains("gated") {
                throw APIError(403, t("Kein Zugang zu \(model.name): auf Hugging Face die Lizenz von Lightricks/LTX-2.5 annehmen und in den Einstellungen ein Token hinterlegen.",
                                      "No access to \(model.name): accept the license of Lightricks/LTX-2.5 on Hugging Face and add a token in the settings."))
            }
            throw error
        }
        try Data().write(to: marker(model))
        progress(1, t("fertig", "done"))
    }

    /// Entfernt die Markierung; die Dateien selbst nur, wenn kein anderes LTX-2-Modell sie mehr braucht (Text-Encoder
    /// und VAE teilen sich 2.3 und 2.5 zum Teil).
    static func delete(_ model: VideoModel) {
        try? FileManager.default.removeItem(at: marker(model))
        if !VideoCatalog.models.contains(where: { $0.isLTX2 && $0.id != model.id && $0.installed }) {
            try? FileManager.default.removeItem(at: directory)
        } else if let raw = model.ltx2 {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("ltx-\(raw)"))
        }
    }

    func unload() {
        pipeline = nil
        loadedID = nil
        Memory.clearCache()
    }

    /// Ein Clip mit Ton als MP4 im Temp-Ordner.
    func generate(model: VideoModel, prompt: String, width: Int, height: Int, frames: Int, fps: Int, seed: UInt64,
                  startImage: CGImage?, onStep: @escaping @Sendable (Int, Int) -> Void) async throws -> VideoEngine.Result {
        try Self.checkOS()
        var timings: [String: Double] = [:]
        var t0 = Date()
        if loadedID != model.id || pipeline == nil {
            pipeline = nil
            Memory.clearCache()
            let p = try Self.makePipeline(model)
            try await p.loadModels()
            try await p.loadAudioModels()
            pipeline = p
            loadedID = model.id
            timings["load"] = Date().timeIntervalSince(t0)
        }
        guard let pipeline else { throw APIError(500, "LTX-2 pipeline") }
        let upscaler = try await pipeline.downloadUpscalerWeights()
        var imagePath: String?
        if let startImage {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvai-ltx2-start-\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw APIError(500, t("Startbild nicht schreibbar.", "Cannot write the start image."))
            }
            CGImageDestinationAddImage(dest, startImage, nil)
            guard CGImageDestinationFinalize(dest) else { throw APIError(500, t("Startbild nicht schreibbar.", "Cannot write the start image.")) }
            imagePath = url.path
        }
        defer { if let imagePath { try? FileManager.default.removeItem(atPath: imagePath) } }
        t0 = Date()
        let config = LTXVideoGenerationConfig(width: width, height: height, numFrames: frames, numSteps: 8, seed: seed,
                                              imagePath: imagePath)
        let result = try await pipeline.generateVideo(prompt: prompt, config: config, upscalerWeightsPath: upscaler) { p in
            onStep(p.currentStep + 1, p.totalSteps)
        }
        timings["generate"] = Date().timeIntervalSince(t0)
        t0 = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvai-ltx2-\(UUID().uuidString).mp4")
        _ = try await VideoExporter.exportVideo(frames: result.frames, width: result.width, height: result.height,
                                                fps: Double(fps), audioWaveform: result.audioWaveform,
                                                audioSampleRate: result.audioSampleRate ?? 24000, to: url)
        timings["mp4"] = Date().timeIntervalSince(t0)
        if SystemInfo.memoryGB < 96 { unload() }  // die anderen Modelle brauchen den Speicher wieder
        return VideoEngine.Result(url: url, frames: result.numFrames, timings: timings)
    }
}
