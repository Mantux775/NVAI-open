// LTX2TransformerBlock.swift - Dual Video/Audio Transformer Block for LTX-2
// Implements the LTX2VideoTransformerBlock from HuggingFace Diffusers
// Each block processes parallel video and audio streams with cross-modal attention
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXFast
import MLXNN

// MARK: - Audio Transformer Arguments

/// Arguments for the audio stream in dual video/audio transformer blocks
struct AudioTransformerArgs {
    /// Audio hidden states (B, T_audio, D_audio)
    var x: MLXArray

    /// Audio text context for cross-attention (B, S, D_audio)
    var context: MLXArray

    /// Audio timestep embeddings for AdaLN (B, 1, numSST, D_audio)
    var timesteps: MLXArray

    /// Audio RoPE position embeddings (cos, sin) — 1D temporal
    var positionalEmbeddings: (cos: MLXArray, sin: MLXArray)

    /// Audio attention mask for text cross-attention
    var contextMask: MLXArray?

    /// Raw audio embedded timestep
    var embeddedTimestep: MLXArray?

    // Cross-modal modulation (from global timestep embeddings)
    //
    // Scale/shift and gate are genuinely different shapes upstream — not a
    // stylistic split. `_prepare_cross_attention_timestep` (ltx-core
    // transformer_args.py) feeds the scale/shift AdaLN this modality's own
    // PER-TOKEN timesteps (reshaped back to one value per token), but feeds
    // the gate AdaLN the cross modality's scalar `sigma` (one value for the
    // whole batch, broadcast to every token). Fusing them into one (B,1,5,D)
    // tensor — as an earlier version of this struct did — silently forces
    // the per-token scale/shift down to a single broadcast value too.

    /// Video cross-modal scale/shift: (B, T_video, 4, D_video), one value per
    /// *video* token — own-modality per-token timesteps, not a global scalar.
    var crossVideoScaleShift: MLXArray

    /// Video cross-modal gate: (B, 1, 1, D_video) — cross-modality (audio)
    /// scalar sigma, broadcast uniformly over every video token.
    var crossVideoGate: MLXArray

    /// Audio cross-modal scale/shift: (B, T_audio, 4, D_audio), one value per
    /// *audio* token.
    var crossAudioScaleShift: MLXArray

    /// Audio cross-modal gate: (B, 1, 1, D_audio) — cross-modality (video)
    /// scalar sigma, broadcast uniformly over every audio token.
    var crossAudioGate: MLXArray

    /// Cross-modal video RoPE (for KV in v2a, Q in a2v cross-attention)
    var crossVideoRoPE: (cos: MLXArray, sin: MLXArray)

    /// Cross-modal audio RoPE (for KV in a2v, Q in v2a cross-attention)
    var crossAudioRoPE: (cos: MLXArray, sin: MLXArray)

    /// Prompt timestep embeddings for cross-attention AdaLN (LTX-2.3)
    /// Video: (B, 1, 2, D_video), Audio: (B, 1, 2, D_audio)
    var videoPromptTimesteps: MLXArray?
    var audioPromptTimesteps: MLXArray?
}

// MARK: - LTX2 Transformer Block

/// Dual video/audio transformer block with cross-modal attention
///
/// Architecture per block:
///     1. Video self-attention  |  Audio self-attention
///     2. Video text cross-attention  |  Audio text cross-attention
///     3. A2V cross-attention + V2A cross-attention
///     4. Video FFN  |  Audio FFN
///
/// Weight keys match Python Diffusers `LTX2VideoTransformerBlock`:
///   Video: norm1, attn1, norm2, attn2, norm3, ff, scale_shift_table
///   Audio: audio_norm1, audio_attn1, ..., audio_scale_shift_table
///   Cross-modal: audio_to_video_{norm,attn}, video_to_audio_{norm,attn}
///   Cross-modal SST: video_a2v_cross_attn_scale_shift_table, audio_a2v_cross_attn_scale_shift_table
class LTX2TransformerBlock: Module {
    let normEps: Float
    let videoDim: Int
    let audioDim: Int
    let numSSTValues: Int  // 6 for LTX-2, 9 for LTX-2.3

    /// When true, video self-attention is skipped (STG perturbation)
    var skipVideoSelfAttention: Bool = false


    // --- Video modules ---
    @ModuleInfo(key: "norm1") var norm1: RMSNorm
    @ModuleInfo(key: "attn1") var attn1: LTXAttention
    @ModuleInfo(key: "norm2") var norm2: RMSNorm
    @ModuleInfo(key: "attn2") var attn2: LTXAttention
    @ModuleInfo(key: "norm3") var norm3: RMSNorm
    @ModuleInfo(key: "ff") var ff: LTXFeedForward
    @ParameterInfo(key: "scale_shift_table") var scaleShiftTable: MLXArray

    // --- Audio modules ---
    @ModuleInfo(key: "audio_norm1") var audioNorm1: RMSNorm
    @ModuleInfo(key: "audio_attn1") var audioAttn1: LTXAttention
    @ModuleInfo(key: "audio_norm2") var audioNorm2: RMSNorm
    @ModuleInfo(key: "audio_attn2") var audioAttn2: LTXAttention
    @ModuleInfo(key: "audio_norm3") var audioNorm3: RMSNorm
    @ModuleInfo(key: "audio_ff") var audioFf: LTXFeedForward
    @ParameterInfo(key: "audio_scale_shift_table") var audioScaleShiftTable: MLXArray

    // --- Cross-modal modules ---
    @ModuleInfo(key: "audio_to_video_norm") var audioToVideoNorm: RMSNorm
    @ModuleInfo(key: "audio_to_video_attn") var audioToVideoAttn: LTXAttention
    @ModuleInfo(key: "video_to_audio_norm") var videoToAudioNorm: RMSNorm
    @ModuleInfo(key: "video_to_audio_attn") var videoToAudioAttn: LTXAttention

    // --- Cross-modal scale-shift tables ---
    @ParameterInfo(key: "scale_shift_table_a2v_ca_video") var videoA2VCrossAttnSST: MLXArray
    @ParameterInfo(key: "scale_shift_table_a2v_ca_audio") var audioA2VCrossAttnSST: MLXArray

    // --- Prompt modulation (LTX-2.3) ---
    @ParameterInfo(key: "prompt_scale_shift_table") var promptScaleShiftTable: MLXArray?
    @ParameterInfo(key: "audio_prompt_scale_shift_table") var audioPromptScaleShiftTable: MLXArray?

    init(
        videoDim: Int,
        videoNumHeads: Int,
        videoHeadDim: Int,
        videoCrossAttentionDim: Int,
        audioDim: Int,
        audioNumHeads: Int,
        audioHeadDim: Int,
        audioCrossAttentionDim: Int,
        ropeType: LTXRopeType = .split,
        normEps: Float = 1e-6,
        gatedAttention: Bool = false,
        crossAttentionAdaLN: Bool = false,
        ffBias: Bool = true,
        audioFfBias: Bool = true
    ) {
        self.normEps = normEps
        self.videoDim = videoDim
        self.audioDim = audioDim
        self.numSSTValues = crossAttentionAdaLN ? 9 : 6

        // --- Video ---
        self._norm1.wrappedValue = RMSNorm(dims: videoDim, eps: normEps)
        self._attn1.wrappedValue = LTXAttention(
            queryDim: videoDim, contextDim: nil,
            heads: videoNumHeads, dimHead: videoHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )
        self._norm2.wrappedValue = RMSNorm(dims: videoDim, eps: normEps)
        self._attn2.wrappedValue = LTXAttention(
            queryDim: videoDim, contextDim: videoCrossAttentionDim,
            heads: videoNumHeads, dimHead: videoHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )
        self._norm3.wrappedValue = RMSNorm(dims: videoDim, eps: normEps)
        self._ff.wrappedValue = LTXFeedForward(dim: videoDim, dimOut: videoDim, bias: ffBias)
        self._scaleShiftTable.wrappedValue = MLXArray.zeros([numSSTValues, videoDim])

        // --- Audio ---
        self._audioNorm1.wrappedValue = RMSNorm(dims: audioDim, eps: normEps)
        self._audioAttn1.wrappedValue = LTXAttention(
            queryDim: audioDim, contextDim: nil,
            heads: audioNumHeads, dimHead: audioHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )
        self._audioNorm2.wrappedValue = RMSNorm(dims: audioDim, eps: normEps)
        self._audioAttn2.wrappedValue = LTXAttention(
            queryDim: audioDim, contextDim: audioCrossAttentionDim,
            heads: audioNumHeads, dimHead: audioHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )
        self._audioNorm3.wrappedValue = RMSNorm(dims: audioDim, eps: normEps)
        self._audioFf.wrappedValue = LTXFeedForward(dim: audioDim, dimOut: audioDim, bias: audioFfBias)
        self._audioScaleShiftTable.wrappedValue = MLXArray.zeros([numSSTValues, audioDim])

        // --- Cross-modal ---
        self._audioToVideoNorm.wrappedValue = RMSNorm(dims: videoDim, eps: normEps)
        self._audioToVideoAttn.wrappedValue = LTXAttention(
            queryDim: videoDim, contextDim: audioDim,
            heads: audioNumHeads, dimHead: audioHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )
        self._videoToAudioNorm.wrappedValue = RMSNorm(dims: audioDim, eps: normEps)
        self._videoToAudioAttn.wrappedValue = LTXAttention(
            queryDim: audioDim, contextDim: videoDim,
            heads: audioNumHeads, dimHead: audioHeadDim,
            normEps: normEps, ropeType: ropeType,
            gatedAttention: gatedAttention
        )

        // Cross-modal scale-shift tables
        self._videoA2VCrossAttnSST.wrappedValue = MLXArray.zeros([5, videoDim])
        self._audioA2VCrossAttnSST.wrappedValue = MLXArray.zeros([5, audioDim])

        // Prompt modulation (LTX-2.3)
        if crossAttentionAdaLN {
            self._promptScaleShiftTable.wrappedValue = MLXArray.zeros([2, videoDim])
            self._audioPromptScaleShiftTable.wrappedValue = MLXArray.zeros([2, audioDim])
        }
    }

    // MARK: - Forward Pass

    func callAsFunction(
        _ videoArgs: TransformerArgs,
        audio audioArgs: AudioTransformerArgs
    ) -> (TransformerArgs, AudioTransformerArgs) {
        var videoX = videoArgs.x
        var audioX = audioArgs.x

        // Get video AdaLN values from SST + timestep
        let videoSST = scaleShiftTable.reshaped([1, 1, numSSTValues, videoDim]) + videoArgs.timesteps
        let (vShiftMSA, vScaleMSA, vGateMSA) = (
            videoSST[0..., 0..., 0, 0...],
            videoSST[0..., 0..., 1, 0...],
            videoSST[0..., 0..., 2, 0...]
        )

        // FFN always uses SST indices 3,4,5 (matching Lightricks reference: slice(3, 6))
        let ffIdx = 3
        let (vShiftMLP, vScaleMLP, vGateMLP) = (
            videoSST[0..., 0..., ffIdx, 0...],
            videoSST[0..., 0..., ffIdx + 1, 0...],
            videoSST[0..., 0..., ffIdx + 2, 0...]
        )

        // Get audio AdaLN values
        let audioSST = audioScaleShiftTable.reshaped([1, 1, numSSTValues, audioDim]) + audioArgs.timesteps
        let (aShiftMSA, aScaleMSA, aGateMSA) = (
            audioSST[0..., 0..., 0, 0...],
            audioSST[0..., 0..., 1, 0...],
            audioSST[0..., 0..., 2, 0...]
        )
        let (aShiftMLP, aScaleMLP, aGateMLP) = (
            audioSST[0..., 0..., ffIdx, 0...],
            audioSST[0..., 0..., ffIdx + 1, 0...],
            audioSST[0..., 0..., ffIdx + 2, 0...]
        )

        // Phase 1: Video self-attention (skip for STG perturbation)
        if skipVideoSelfAttention {
            // STG: skip video self-attention, residual unchanged
        } else {
            let normV1 = norm1(videoX) * (1 + vScaleMSA) + vShiftMSA
            let vSelfOut = attn1(normV1, pe: videoArgs.positionalEmbeddings)
            videoX = videoX + vSelfOut * vGateMSA
        }

        // Phase 2: Audio self-attention
        let normA1 = audioNorm1(audioX) * (1 + aScaleMSA) + aShiftMSA
        let aSelfOut = audioAttn1(normA1, pe: audioArgs.positionalEmbeddings)
        audioX = audioX + aSelfOut * aGateMSA

        // Phase 3-4: Text cross-attention
        if numSSTValues == 9 {
            // LTX-2.3: cross-attention with AdaLN on query and prompt
            // Reference: slice(6, 9) — cross-attention uses SST indices 6,7,8
            let (vShiftCA, vScaleCA, vGateCA) = (
                videoSST[0..., 0..., 6, 0...],
                videoSST[0..., 0..., 7, 0...],
                videoSST[0..., 0..., 8, 0...]
            )
            let (aShiftCA, aScaleCA, aGateCA) = (
                audioSST[0..., 0..., 6, 0...],
                audioSST[0..., 0..., 7, 0...],
                audioSST[0..., 0..., 8, 0...]
            )

            // Video cross-attention with AdaLN
            let normV2 = norm2(videoX) * (1 + vScaleCA) + vShiftCA
            var videoCtx = videoArgs.context
            if let pSST = promptScaleShiftTable, let pTs = audioArgs.videoPromptTimesteps {
                let pMod = pSST.reshaped([1, 1, 2, videoDim]) + pTs
                videoCtx = videoCtx * (1 + pMod[0..., 0..., 1, 0...]) + pMod[0..., 0..., 0, 0...]
            }
            let vCrossOut = attn2(normV2, context: videoCtx, mask: videoArgs.contextMask)
            videoX = videoX + vCrossOut * vGateCA

            // Audio cross-attention with AdaLN
            let normA2 = audioNorm2(audioX) * (1 + aScaleCA) + aShiftCA
            var audioCtx = audioArgs.context
            if let apSST = audioPromptScaleShiftTable, let apTs = audioArgs.audioPromptTimesteps {
                let apMod = apSST.reshaped([1, 1, 2, audioDim]) + apTs
                audioCtx = audioCtx * (1 + apMod[0..., 0..., 1, 0...]) + apMod[0..., 0..., 0, 0...]
            }
            let aCrossOut = audioAttn2(normA2, context: audioCtx, mask: audioArgs.contextMask)
            audioX = audioX + aCrossOut * aGateCA
        } else {
            // LTX-2: cross-attention without AdaLN
            let normV2 = norm2(videoX)
            let vCrossOut = attn2(normV2, context: videoArgs.context, mask: videoArgs.contextMask)
            videoX = videoX + vCrossOut

            let normA2 = audioNorm2(audioX)
            let aCrossOut = audioAttn2(normA2, context: audioArgs.context, mask: audioArgs.contextMask)
            audioX = audioX + aCrossOut
        }

        // Phase 5-6: Cross-modal attention (A2V and V2A)
        // Scale/shift (per-block learned table rows 0-3) combines with the
        // PER-TOKEN own-modality embedding; gate (row 4) combines with the
        // scalar cross-modality embedding — see AudioTransformerArgs' doc
        // comment for why these can't be fused into one broadcast tensor.
        let videoScaleShiftCA = videoA2VCrossAttnSST[0 ..< 4, 0...].reshaped([1, 1, 4, videoDim])
            + audioArgs.crossVideoScaleShift
        let videoGateCA = videoA2VCrossAttnSST[4 ..< 5, 0...].reshaped([1, 1, 1, videoDim])
            + audioArgs.crossVideoGate
        let audioScaleShiftCA = audioA2VCrossAttnSST[0 ..< 4, 0...].reshaped([1, 1, 4, audioDim])
            + audioArgs.crossAudioScaleShift
        let audioGateCA = audioA2VCrossAttnSST[4 ..< 5, 0...].reshaped([1, 1, 1, audioDim])
            + audioArgs.crossAudioGate

        // Video modulation values
        let vA2VScale = videoScaleShiftCA[0..., 0..., 0, 0...]
        let vA2VShift = videoScaleShiftCA[0..., 0..., 1, 0...]
        let vV2AScale = videoScaleShiftCA[0..., 0..., 2, 0...]
        let vV2AShift = videoScaleShiftCA[0..., 0..., 3, 0...]
        let vA2VGate = videoGateCA[0..., 0..., 0, 0...]

        // Audio modulation values
        let aA2VScale = audioScaleShiftCA[0..., 0..., 0, 0...]
        let aA2VShift = audioScaleShiftCA[0..., 0..., 1, 0...]
        let aV2AScale = audioScaleShiftCA[0..., 0..., 2, 0...]
        let aV2AShift = audioScaleShiftCA[0..., 0..., 3, 0...]
        let aV2AGate = audioGateCA[0..., 0..., 0, 0...]

        // Norm video and audio for cross-modal
        let normVCA = audioToVideoNorm(videoX)
        let normACA = videoToAudioNorm(audioX)

        // Phase 5: A2V cross-attention (audio modulates video)
        let modV_a2v = normVCA * (1 + vA2VScale) + vA2VShift
        let modA_a2v = normACA * (1 + aA2VScale) + aA2VShift
        let a2vOut = audioToVideoAttn(
            modV_a2v,
            context: modA_a2v,
            pe: audioArgs.crossVideoRoPE,
            kPe: audioArgs.crossAudioRoPE
        )
        videoX = videoX + a2vOut * vA2VGate

        // Phase 6: V2A cross-attention (video modulates audio)
        let modA_v2a = normACA * (1 + aV2AScale) + aV2AShift
        let modV_v2a = normVCA * (1 + vV2AScale) + vV2AShift
        let v2aOut = videoToAudioAttn(
            modA_v2a,
            context: modV_v2a,
            pe: audioArgs.crossAudioRoPE,
            kPe: audioArgs.crossVideoRoPE
        )
        audioX = audioX + v2aOut * aV2AGate

        // Phase 7: Video FFN
        let normV3 = norm3(videoX) * (1 + vScaleMLP) + vShiftMLP
        let vFFOut = ff(normV3)
        videoX = videoX + vFFOut * vGateMLP

        // Phase 8: Audio FFN
        let normA3 = audioNorm3(audioX) * (1 + aScaleMLP) + aShiftMLP
        let aFFOut = audioFf(normA3)
        audioX = audioX + aFFOut * aGateMLP

        return (
            videoArgs.replacing(x: videoX),
            AudioTransformerArgs(
                x: audioX,
                context: audioArgs.context,
                timesteps: audioArgs.timesteps,
                positionalEmbeddings: audioArgs.positionalEmbeddings,
                contextMask: audioArgs.contextMask,
                embeddedTimestep: audioArgs.embeddedTimestep,
                crossVideoScaleShift: audioArgs.crossVideoScaleShift,
                crossVideoGate: audioArgs.crossVideoGate,
                crossAudioScaleShift: audioArgs.crossAudioScaleShift,
                crossAudioGate: audioArgs.crossAudioGate,
                crossVideoRoPE: audioArgs.crossVideoRoPE,
                crossAudioRoPE: audioArgs.crossAudioRoPE,
                videoPromptTimesteps: audioArgs.videoPromptTimesteps,
                audioPromptTimesteps: audioArgs.audioPromptTimesteps
            )
        )
    }

}
