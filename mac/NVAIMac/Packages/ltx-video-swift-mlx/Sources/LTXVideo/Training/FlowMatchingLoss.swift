// FlowMatchingLoss.swift - Flow-matching velocity prediction loss
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXRandom
import MLXNN

/// Flow-matching loss for training LoRA on LTX-2 transformers.
///
/// Computes MSE loss between predicted and target velocities:
/// 1. Sample sigma ~ U(0, 1)
/// 2. Create noisy sample: x_t = (1-σ)·latent + σ·noise
/// 3. Forward transformer → predicted velocity
/// 4. Target velocity: v = noise - latent
/// 5. Loss = MSE(pred, target)
struct FlowMatchingLoss {

    /// Compute flow-matching loss for video-only transformer (LTXTransformer)
    ///
    /// - Parameters:
    ///   - model: The transformer model (with LoRA layers)
    ///   - videoLatent: Clean video latent (B, T_video, C) — already patchified
    ///   - promptEmbeddings: Text embeddings (B, S, D)
    ///   - promptMask: Attention mask (B, S)
    ///   - latentShape: Video latent dimensions (frames, height, width)
    ///   - scheduler: LTX scheduler for noise operations
    /// - Returns: Scalar loss value
    static func videoLoss(
        model: LTXTransformer,
        videoLatent: MLXArray,
        promptEmbeddings: MLXArray,
        promptMask: MLXArray,
        latentShape: (frames: Int, height: Int, width: Int),
        scheduler: LTXScheduler
    ) -> MLXArray {
        let batchSize = videoLatent.dim(0)

        // Sample random sigma (timestep) for each batch element
        let sigma = MLXRandom.uniform(0..<1, [batchSize, 1]).asType(.float32)

        // Generate noise matching latent shape
        let noise = MLXRandom.normal(videoLatent.shape).asType(videoLatent.dtype)

        // Create noisy sample: x_t = (1-σ)·latent + σ·noise
        let sigmaExpanded = sigma.asType(videoLatent.dtype)
        let noisyLatent = (1 - sigmaExpanded) * videoLatent + sigmaExpanded * noise

        // Forward pass — sigma needs to be (B,) for timestep embedding
        let sigmaFlat = sigma.squeezed(axis: 1)

        // Cast noisy latent to bf16 for transformer input
        let modelInput = noisyLatent.asType(DType.bfloat16)

        let predicted = model(
            latent: modelInput,
            context: promptEmbeddings,
            timesteps: sigmaFlat,
            contextMask: promptMask,
            latentShape: latentShape
        )

        // Target velocity: v = noise - latent
        let target = (noise - videoLatent).asType(predicted.dtype)

        // MSE loss
        return mseLoss(predictions: predicted, targets: target, reduction: .mean)
    }

    /// Compute flow-matching loss for dual video/audio transformer (LTX2Transformer)
    ///
    /// - Parameters:
    ///   - model: The dual transformer model (with LoRA layers)
    ///   - videoLatent: Clean video latent (B, T_video, C)
    ///   - audioLatent: Clean audio latent (B, T_audio, C_audio)
    ///   - videoEmbeddings: Video text embeddings (B, S, D)
    ///   - audioEmbeddings: Audio text embeddings (B, S, D)
    ///   - videoMask: Video attention mask (B, S)
    ///   - audioMask: Audio attention mask (B, S)
    ///   - videoLatentShape: Video latent dimensions (frames, height, width)
    ///   - audioNumFrames: Number of audio latent frames
    ///   - audioLossWeight: Weight for audio loss relative to video
    /// - Returns: Scalar loss value (video_loss + weight * audio_loss)
    static func dualLoss(
        model: LTX2Transformer,
        videoLatent: MLXArray,
        audioLatent: MLXArray,
        videoEmbeddings: MLXArray,
        audioEmbeddings: MLXArray,
        videoMask: MLXArray,
        audioMask: MLXArray,
        videoLatentShape: (frames: Int, height: Int, width: Int),
        audioNumFrames: Int,
        audioLossWeight: Float = 0.5
    ) -> MLXArray {
        let batchSize = videoLatent.dim(0)

        // Shared sigma for video and audio (same timestep)
        let sigma = MLXRandom.uniform(0..<1, [batchSize, 1]).asType(.float32)

        // Video noise
        let videoNoise = MLXRandom.normal(videoLatent.shape).asType(videoLatent.dtype)
        let sigmaVideo = sigma.asType(videoLatent.dtype)
        let noisyVideo = (1 - sigmaVideo) * videoLatent + sigmaVideo * videoNoise

        // Audio noise
        let audioNoise = MLXRandom.normal(audioLatent.shape).asType(audioLatent.dtype)
        let sigmaAudio = sigma.asType(audioLatent.dtype)
        let noisyAudio = (1 - sigmaAudio) * audioLatent + sigmaAudio * audioNoise

        // Forward pass
        let sigmaFlat = sigma.squeezed(axis: 1)
        let (predVideo, predAudio) = model(
            videoLatent: noisyVideo.asType(DType.bfloat16),
            audioLatent: noisyAudio.asType(DType.bfloat16),
            videoContext: videoEmbeddings,
            audioContext: audioEmbeddings,
            videoTimesteps: sigmaFlat,
            audioTimesteps: sigmaFlat,
            videoContextMask: videoMask,
            audioContextMask: audioMask,
            videoLatentShape: videoLatentShape,
            audioNumFrames: audioNumFrames
        )

        // Target velocities
        let videoTarget = (videoNoise - videoLatent).asType(predVideo.dtype)
        let audioTarget = (audioNoise - audioLatent).asType(predAudio.dtype)

        // Combined MSE loss
        let videoLoss = mseLoss(predictions: predVideo, targets: videoTarget, reduction: .mean)
        let audioLoss = mseLoss(predictions: predAudio, targets: audioTarget, reduction: .mean)

        return videoLoss + audioLossWeight * audioLoss
    }
}
