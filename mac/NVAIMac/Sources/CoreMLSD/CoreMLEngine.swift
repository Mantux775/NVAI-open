import Foundation
import CoreGraphics
import CoreML
import StableDiffusion

/// Abbruchwunsch, den der Fortschritts-Abschluss mitten in `generateImages` liest.
/// Ein Actor-Feld ginge nicht: der Abschluss läuft synchron im Rechenaufruf.
final class CancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Core-ML-Stable-Diffusion – übernommen aus NVAILocal (ImageGenerator), für macOS.
/// Ein eigener Actor: `generateImages` ist synchron und läuft Sekunden bis Minuten.
actor CoreMLEngine {
    static let shared = CoreMLEngine()

    private var pipeline: (any StableDiffusionPipelineProtocol)?
    private var loadedModelID: String?
    private let signal = CancelSignal()

    func currentModelID() -> String? { loadedModelID }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
        loadedModelID = nil
    }

    /// Lädt nur, wenn ein anderes Modell aktiv ist – der Ladevorgang kostet Sekunden.
    func load(_ model: CoreMLModel) throws {
        guard loadedModelID != model.id || pipeline == nil else { return }
        unload()
        guard let resources = CoreMLCatalog.resources(model) else {
            throw APIError(409, t("„\(model.name)“ ist nicht vollständig geladen.", "\"\(model.name)\" is not completely downloaded."))
        }
        let config = MLModelConfiguration()
        // split_einsum ist für die Neural Engine gebaut, original für die GPU.
        config.computeUnits = model.nutztGPU ? .cpuAndGPU : .cpuAndNeuralEngine
        let reduceMemory = SystemInfo.memoryGB <= 16
        if model.isXL {
            pipeline = try StableDiffusionXLPipeline(resourcesAt: resources, configuration: config,
                                                     reduceMemory: reduceMemory)
        } else {
            pipeline = try StableDiffusionPipeline(resourcesAt: resources, controlNet: [], configuration: config,
                                                   disableSafety: false, reduceMemory: reduceMemory)
        }
        try pipeline?.loadResources()
        loadedModelID = model.id
    }

    /// Bricht das laufende Bild beim nächsten Schritt ab (anders als FLUX.2 kann Core ML das).
    nonisolated func requestCancel() { signal.set() }

    /// Ein Bild. `startingImage` + `strength` für Bild-zu-Bild (braucht den VAE-Encoder).
    func generate(model: CoreMLModel, prompt: String, negative: String, steps: Int, guidance: Float,
                  seed: UInt32, startingImage: CGImage?, strength: Float,
                  onProgress: @escaping @Sendable (Int, Int) -> Void) throws -> CGImage {
        try load(model)
        guard let pipeline else { throw APIError(500, t("Kein Modell geladen.", "No model loaded.")) }
        signal.reset()
        let signal = self.signal
        var config = StableDiffusionPipeline.Configuration(prompt: prompt)
        config.negativePrompt = negative
        config.stepCount = steps
        config.seed = seed
        config.guidanceScale = guidance
        config.imageCount = 1
        config.schedulerType = .dpmSolverMultistepScheduler
        if let startingImage {
            config.startingImage = startingImage
            config.strength = max(0.05, min(1, strength))
        }
        let images = try pipeline.generateImages(configuration: config) { progress in
            onProgress(progress.step, progress.stepCount)
            return !signal.isSet
        }
        if signal.isSet { throw CancellationError() }
        guard let image = images.compactMap({ $0 }).first else {
            throw APIError(500, t("Core ML hat kein Bild geliefert (Sicherheitsfilter oder Speicher).",
                                  "Core ML returned no image (safety filter or memory)."))
        }
        return image
    }
}
