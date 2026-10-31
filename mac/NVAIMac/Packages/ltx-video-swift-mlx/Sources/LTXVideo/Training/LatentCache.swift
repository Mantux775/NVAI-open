// LatentCache.swift - Pre-computed latent cache for efficient training
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// Pre-computed latent cache for training.
///
/// Encodes all training videos/audio through VAE and text through Gemma+connector once,
/// then stores on disk as safetensors for fast loading during training.
/// This allows VAE and Gemma to be unloaded, saving ~30GB+ RAM.
struct CachedSample: Sendable {
    /// Video latent (1, T_video, C) — patchified and packed
    let videoLatent: MLXArray
    /// Video latent shape info
    let latentFrames: Int
    let latentHeight: Int
    let latentWidth: Int
    /// Text embeddings for video (1, S, D)
    let promptEmbeddings: MLXArray
    /// Attention mask (1, S)
    let promptMask: MLXArray
    /// Audio latent (1, T_audio, C_audio) — optional
    let audioLatent: MLXArray?
    /// Audio text embeddings (1, S, D) — optional
    let audioEmbeddings: MLXArray?
    /// Audio attention mask (1, S) — optional
    let audioMask: MLXArray?
    /// Audio latent frames count — optional
    let audioNumFrames: Int?
    /// I2V conditioning image latent (1, 128, 1, H/32, W/32) — optional.
    /// Present when a .png conditioning image exists alongside the source video.
    let imageLatent: MLXArray?
    /// Source filename
    let filename: String
}

/// Manages the latent cache directory
class LatentCache {
    let cacheDir: String
    let triggerWord: String?
    private var cachedSamples: [CachedSample] = []

    init(cacheDir: String, triggerWord: String? = nil) {
        self.cacheDir = cacheDir
        self.triggerWord = triggerWord
    }

    /// Build cache from dataset using the pipeline's encoder components.
    ///
    /// - Parameters:
    ///   - dataset: Video dataset to encode
    ///   - pipeline: Pipeline with loaded models (VAE encoder, Gemma, text encoder)
    ///   - progressCallback: Called with (currentIndex, total, filename)
    func build(
        from dataset: VideoDataset,
        pipeline: LTXPipeline,
        progressCallback: ((Int, Int, String) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir) {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }

        for i in 0..<dataset.count {
            let sample = try await dataset.loadSample(at: i)
            progressCallback?(i, dataset.count, sample.filename)

            let cachePath = samplePath(for: sample.filename)

            // Skip if already cached
            if fm.fileExists(atPath: cachePath) {
                LTXDebug.log("Cache hit: \(sample.filename)")
                continue
            }

            // Encode video frames through VAE encoder
            let videoLatent = try await pipeline.encodeVideoLatents(frames: sample.frames)
            eval(videoLatent)

            // Encode text through Gemma + connector (prepend trigger word if set)
            let caption: String
            if let trigger = triggerWord {
                caption = "\(trigger) \(sample.caption)"
            } else {
                caption = sample.caption
            }
            let textResult = try await pipeline.encodeText(caption)
            eval(textResult.embeddings, textResult.mask)

            // Compute latent spatial dimensions from input frames (1, 3, T, H, W)
            let numFrames = sample.frames.dim(2)
            let latentFrames = (numFrames - 1) / 8 + 1
            let frameH = sample.frames.dim(3)
            let frameW = sample.frames.dim(4)
            let latentH = frameH / 32
            let latentW = frameW / 32

            // Encode I2V conditioning image if present
            var imageLatent: MLXArray? = nil
            if let imageFrames = sample.image {
                // imageFrames is (1, 3, 1, H, W) — encode as a single-frame video
                let imgLatent = try await pipeline.encodeVideoLatents(frames: imageFrames)
                eval(imgLatent)
                imageLatent = imgLatent
                LTXDebug.log("  Image latent encoded: \(imgLatent.shape)")
            }

            // Build save dictionary with shape metadata
            var saveDict: [String: MLXArray] = [
                "video_latent": videoLatent,
                "prompt_embeddings": textResult.embeddings,
                "prompt_mask": textResult.mask,
                "latent_frames": MLXArray(Int32(latentFrames)),
                "latent_height": MLXArray(Int32(latentH)),
                "latent_width": MLXArray(Int32(latentW)),
            ]
            if let imgLatent = imageLatent {
                saveDict["image_latent"] = imgLatent
            }

            // Save to disk
            let url = URL(fileURLWithPath: cachePath)
            try MLX.save(arrays: saveDict, url: url)

            LTXDebug.log("Cached: \(sample.filename) → \(cachePath)")

            // Clear GPU cache after each encoding
            Memory.clearCache()
        }
    }

    /// Load all cached samples into memory
    func loadAll() throws {
        cachedSamples = []

        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: cacheDir)
        let safetensorsFiles = contents.filter { $0.hasSuffix(".safetensors") }
            .sorted()

        for file in safetensorsFiles {
            let path = (cacheDir as NSString).appendingPathComponent(file)
            let arrays = try MLX.loadArrays(url: URL(fileURLWithPath: path))

            guard let videoLatent = arrays["video_latent"],
                  let promptEmbeddings = arrays["prompt_embeddings"],
                  let promptMask = arrays["prompt_mask"]
            else {
                print("Warning: Incomplete cache file \(file), skipping")
                continue
            }

            // Read shape metadata (stored during build)
            let lFrames: Int
            let lHeight: Int
            let lWidth: Int
            if let f = arrays["latent_frames"], let h = arrays["latent_height"], let w = arrays["latent_width"] {
                lFrames = Int(f.item(Int32.self))
                lHeight = Int(h.item(Int32.self))
                lWidth = Int(w.item(Int32.self))
            } else {
                // Legacy cache without shape metadata — cannot use
                print("Warning: Cache file \(file) missing shape metadata, skipping (rebuild cache)")
                continue
            }

            let sample = CachedSample(
                videoLatent: videoLatent,
                latentFrames: lFrames,
                latentHeight: lHeight,
                latentWidth: lWidth,
                promptEmbeddings: promptEmbeddings,
                promptMask: promptMask,
                audioLatent: nil,
                audioEmbeddings: nil,
                audioMask: nil,
                audioNumFrames: nil,
                imageLatent: arrays["image_latent"],
                filename: (file as NSString).deletingPathExtension
            )
            cachedSamples.append(sample)
        }

        LTXDebug.log("Loaded \(cachedSamples.count) cached samples")
    }

    /// Get a random cached sample
    func randomSample() -> CachedSample? {
        guard !cachedSamples.isEmpty else { return nil }
        let idx = Int.random(in: 0..<cachedSamples.count)
        return cachedSamples[idx]
    }

    /// Get sample at index (wraps around)
    func sample(at index: Int) -> CachedSample? {
        guard !cachedSamples.isEmpty else { return nil }
        return cachedSamples[index % cachedSamples.count]
    }

    /// Number of cached samples
    var count: Int { cachedSamples.count }

    /// Whether the cache is populated
    var isEmpty: Bool { cachedSamples.isEmpty }

    /// Validate that cached sample shapes are valid.
    ///
    /// With per-video aspect ratio preservation, each sample may have different
    /// spatial dimensions. We only check that frame count matches and that
    /// spatial dimensions are within the configured budget.
    func validate(config: LoRATrainingConfig) throws {
        let expectedFrames = (config.numFrames - 1) / 8 + 1
        let maxLatentH = config.height / 32
        let maxLatentW = config.width / 32

        for sample in cachedSamples {
            if sample.latentFrames != expectedFrames {
                throw TrainingError.datasetError(
                    "Cache frame count mismatch for \(sample.filename): " +
                    "cached \(sample.latentFrames) vs config \(expectedFrames). " +
                    "Delete the latent_cache directory and re-run to rebuild."
                )
            }
            if sample.latentHeight > maxLatentH || sample.latentWidth > maxLatentW {
                throw TrainingError.datasetError(
                    "Cache spatial size exceeds budget for \(sample.filename): " +
                    "cached \(sample.latentHeight)×\(sample.latentWidth) vs max \(maxLatentH)×\(maxLatentW). " +
                    "Delete the latent_cache directory and re-run to rebuild."
                )
            }
        }
    }

    // MARK: - Private

    private func samplePath(for filename: String) -> String {
        let baseName = (filename as NSString).deletingPathExtension
        return (cacheDir as NSString).appendingPathComponent(baseName + ".safetensors")
    }
}
