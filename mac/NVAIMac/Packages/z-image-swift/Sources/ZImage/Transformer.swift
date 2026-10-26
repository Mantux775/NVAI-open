// ZImageTransformer2DModel — isomorphic port of zimage-oracle src/zimage/transformer.py.
// Same class/method names and forward call order; PyTorch↔MLX op substitutions only.
//
// Deviations forced by the frameworks (each mirrored in the Weights loader remap):
//  - `all_x_embedder`/`all_final_layer` are ModuleDicts keyed "2-1" upstream; the released
//    checkpoints ship exactly one patch config, and mlx-swift Module reflection has no
//    dict-of-module support → single `xEmbedder`/`finalLayer` (loader remaps
//    "all_x_embedder.2-1." → "x_embedder.", "all_final_layer.2-1." → "final_layer.").
//  - `TimestepEmbedder.mlp` is nn.Sequential(Linear, SiLU, Linear) → `mlpIn`/`mlpOut`
//    (loader remaps "mlp.0." → "mlp_in.", "mlp.2." → "mlp_out.").
//  - Learned pad tokens are appended at build time instead of scatter-assigned post-embed;
//    the reference embeds duplicated tail rows then overwrites them with the pad token, so
//    the resulting sequences are identical.
//  - Complex freqs_cis (torch.polar) → real (cos, sin) tables, fp32 (MLX has no complex;
//    Lens T2 pattern). Tables built with Double math on the host — no Float64 on GPU.

import Foundation
import MLX
import MLXFast
import MLXNN

// Config constants — src/config/model.py (verified == checkpoint transformer/config.json).
public enum ZImageConfigConstants {
    public static let adalnEmbedDim = 256
    public static let seqMultiOf = 32
    public static let ropeTheta: Double = 256.0
    public static let ropeAxesDims = [32, 48, 48]
    public static let ropeAxesLens = [1536, 512, 512]
    public static let frequencyEmbeddingSize = 256
    public static let maxPeriod: Double = 10000
}

public final class TimestepEmbedder: Module {
    @ModuleInfo(key: "mlp_in") var mlpIn: Linear
    @ModuleInfo(key: "mlp_out") var mlpOut: Linear
    let frequencyEmbeddingSize: Int

    public init(outSize: Int, midSize: Int? = nil,
                frequencyEmbeddingSize: Int = ZImageConfigConstants.frequencyEmbeddingSize) {
        let mid = midSize ?? outSize
        self._mlpIn.wrappedValue = Linear(frequencyEmbeddingSize, mid, bias: true)
        self._mlpOut.wrappedValue = Linear(mid, outSize, bias: true)
        self.frequencyEmbeddingSize = frequencyEmbeddingSize
    }

    public static func timestepEmbedding(
        _ t: MLXArray, dim: Int, maxPeriod: Double = ZImageConfigConstants.maxPeriod
    ) -> MLXArray {
        // fp32 block (reference wraps in autocast-disabled)
        let half = dim / 2
        let freqs = exp(
            -Float(Foundation.log(maxPeriod)) * MLXArray(0..<half).asType(.float32) / Float(half)
        )
        let args = t.asType(.float32)[0..., .newAxis] * freqs[.newAxis, 0...]
        var embedding = concatenated([cos(args), sin(args)], axis: -1)
        if dim % 2 != 0 {
            embedding = concatenated([embedding, zeros(like: embedding[0..., ..<1])], axis: -1)
        }
        return embedding
    }

    public func callAsFunction(_ t: MLXArray) -> MLXArray {
        var tFreq = Self.timestepEmbedding(t, dim: frequencyEmbeddingSize)
        tFreq = tFreq.asType(mlpIn.weight.dtype)
        return mlpOut(silu(mlpIn(tFreq)))
    }
}

public final class ZImageRMSNorm: Module {
    let eps: Float
    @ModuleInfo var weight: MLXArray

    public init(_ dim: Int, eps: Float = 1e-5) {
        self.eps = eps
        self._weight.wrappedValue = ones([dim])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

public final class FeedForward: Module {
    @ModuleInfo var w1: Linear
    @ModuleInfo var w2: Linear
    @ModuleInfo var w3: Linear

    public init(dim: Int, hiddenDim: Int) {
        self._w1.wrappedValue = Linear(dim, hiddenDim, bias: false)
        self._w2.wrappedValue = Linear(hiddenDim, dim, bias: false)
        self._w3.wrappedValue = Linear(dim, hiddenDim, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        w2(silu(w1(x)) * w3(x))
    }
}

/// Rotate pairs: reference reshapes to complex and multiplies by freqs_cis.
/// Real form: (x0 + i·x1)·(cos + i·sin) = (x0·cos − x1·sin) + i·(x0·sin + x1·cos).
/// x: [B, N, H, D]; cos/sin: [B, N, D/2] (broadcast over heads, matching unsqueeze(2)).
public func applyRotaryEmb(_ xIn: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
    let shape = xIn.shape
    let x = xIn.asType(.float32).reshaped(shape[0], shape[1], shape[2], shape[3] / 2, 2)
    let x0 = x[0..., 0..., 0..., 0..., 0]
    let x1 = x[0..., 0..., 0..., 0..., 1]
    let c = cos[0..., 0..., .newAxis, 0...]
    let s = sin[0..., 0..., .newAxis, 0...]
    let out = stacked([x0 * c - x1 * s, x0 * s + x1 * c], axis: -1)
    return out.reshaped(shape).asType(xIn.dtype)
}

public final class ZImageAttention: Module {
    let nHeads: Int
    let nKVHeads: Int
    let headDim: Int

    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: [Linear]
    @ModuleInfo(key: "norm_q") var normQ: ZImageRMSNorm?
    @ModuleInfo(key: "norm_k") var normK: ZImageRMSNorm?

    public init(dim: Int, nHeads: Int, nKVHeads: Int, qkNorm: Bool = true, eps: Float = 1e-5) {
        self.nHeads = nHeads
        self.nKVHeads = nKVHeads
        self.headDim = dim / nHeads
        self._toQ.wrappedValue = Linear(dim, nHeads * headDim, bias: false)
        self._toK.wrappedValue = Linear(dim, nKVHeads * headDim, bias: false)
        self._toV.wrappedValue = Linear(dim, nKVHeads * headDim, bias: false)
        self._toOut.wrappedValue = [Linear(nHeads * headDim, dim, bias: false)]
        self._normQ.wrappedValue = qkNorm ? ZImageRMSNorm(headDim, eps: eps) : nil
        self._normK.wrappedValue = qkNorm ? ZImageRMSNorm(headDim, eps: eps) : nil
    }

    /// hiddenStates: [B, N, dim]; attentionMask: additive [B, 1, 1, N] or nil;
    /// ropeCos/ropeSin: [B, N, headDim/2] or nil.
    public func callAsFunction(
        _ hiddenStates: MLXArray,
        attentionMask: MLXArray? = nil,
        ropeCos: MLXArray? = nil,
        ropeSin: MLXArray? = nil
    ) -> MLXArray {
        let (B, N) = (hiddenStates.shape[0], hiddenStates.shape[1])
        var query = toQ(hiddenStates).reshaped(B, N, nHeads, headDim)
        var key = toK(hiddenStates).reshaped(B, N, nKVHeads, headDim)
        let value = toV(hiddenStates).reshaped(B, N, nKVHeads, headDim)

        if let normQ { query = normQ(query) }
        if let normK { key = normK(key) }

        if let ropeCos, let ropeSin {
            query = applyRotaryEmb(query, cos: ropeCos, sin: ropeSin)
            key = applyRotaryEmb(key, cos: ropeCos, sin: ropeSin)
        }

        var out = MLXFast.scaledDotProductAttention(
            queries: query.transposed(0, 2, 1, 3),
            keys: key.transposed(0, 2, 1, 3),
            values: value.transposed(0, 2, 1, 3),
            scale: 1.0 / Foundation.sqrt(Float(headDim)),
            mask: attentionMask
        )
        out = out.transposed(0, 2, 1, 3).reshaped(B, N, nHeads * headDim)
        return toOut[0](out)
    }
}

public final class ZImageTransformerBlock: Module {
    let dim: Int
    let layerId: Int
    let modulation: Bool

    @ModuleInfo var attention: ZImageAttention
    @ModuleInfo(key: "feed_forward") var feedForward: FeedForward
    @ModuleInfo(key: "attention_norm1") var attentionNorm1: ZImageRMSNorm
    @ModuleInfo(key: "ffn_norm1") var ffnNorm1: ZImageRMSNorm
    @ModuleInfo(key: "attention_norm2") var attentionNorm2: ZImageRMSNorm
    @ModuleInfo(key: "ffn_norm2") var ffnNorm2: ZImageRMSNorm
    @ModuleInfo(key: "adaLN_modulation") var adaLNModulation: [Linear]?

    public init(
        layerId: Int, dim: Int, nHeads: Int, nKVHeads: Int,
        normEps: Float, qkNorm: Bool, modulation: Bool = true
    ) {
        self.dim = dim
        self.layerId = layerId
        self.modulation = modulation
        self._attention.wrappedValue = ZImageAttention(
            dim: dim, nHeads: nHeads, nKVHeads: nKVHeads, qkNorm: qkNorm, eps: normEps)
        self._feedForward.wrappedValue = FeedForward(dim: dim, hiddenDim: dim / 3 * 8)
        self._attentionNorm1.wrappedValue = ZImageRMSNorm(dim, eps: normEps)
        self._ffnNorm1.wrappedValue = ZImageRMSNorm(dim, eps: normEps)
        self._attentionNorm2.wrappedValue = ZImageRMSNorm(dim, eps: normEps)
        self._ffnNorm2.wrappedValue = ZImageRMSNorm(dim, eps: normEps)
        self._adaLNModulation.wrappedValue = modulation
            ? [Linear(min(dim, ZImageConfigConstants.adalnEmbedDim), 4 * dim, bias: true)]
            : nil
    }

    public func callAsFunction(
        _ x: MLXArray,
        attnMask: MLXArray?,
        ropeCos: MLXArray,
        ropeSin: MLXArray,
        adalnInput: MLXArray? = nil
    ) -> MLXArray {
        var x = x
        if modulation {
            guard let adalnInput, let adaLN = adaLNModulation else {
                fatalError("modulated block requires adaln_input")
            }
            // chunk(4) → scale_msa, gate_msa, scale_mlp, gate_mlp; gates tanh'd, scales 1+.
            let mod = adaLN[0](adalnInput)[0..., .newAxis, 0...]
            let parts = split(mod, parts: 4, axis: 2)
            let scaleMSA = 1.0 + parts[0]
            let gateMSA = tanh(parts[1])
            let scaleMLP = 1.0 + parts[2]
            let gateMLP = tanh(parts[3])

            let attnOut = attention(
                attentionNorm1(x) * scaleMSA,
                attentionMask: attnMask, ropeCos: ropeCos, ropeSin: ropeSin)
            x = x + gateMSA * attentionNorm2(attnOut)
            x = x + gateMLP * ffnNorm2(feedForward(ffnNorm1(x) * scaleMLP))
        } else {
            let attnOut = attention(
                attentionNorm1(x),
                attentionMask: attnMask, ropeCos: ropeCos, ropeSin: ropeSin)
            x = x + attentionNorm2(attnOut)
            x = x + ffnNorm2(feedForward(ffnNorm1(x)))
        }
        return x
    }
}

public final class FinalLayer: Module {
    @ModuleInfo(key: "norm_final") var normFinal: LayerNorm
    @ModuleInfo var linear: Linear
    // nn.Sequential(SiLU, Linear) upstream → SiLU applied functionally; loader remaps
    // "adaLN_modulation.1." → "adaLN_linear.".
    @ModuleInfo(key: "adaLN_linear") var adaLNLinear: Linear

    public init(hiddenSize: Int, outChannels: Int) {
        self._normFinal.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: 1e-6, affine: false)
        self._linear.wrappedValue = Linear(hiddenSize, outChannels, bias: true)
        self._adaLNLinear.wrappedValue = Linear(
            min(hiddenSize, ZImageConfigConstants.adalnEmbedDim), hiddenSize, bias: true)
    }

    public func callAsFunction(_ x: MLXArray, _ c: MLXArray) -> MLXArray {
        let scale = 1.0 + adaLNLinear(silu(c))
        return linear(normFinal(x) * scale[0..., .newAxis, 0...])
    }
}

/// Plain class, NOT a Module — tables must never become parameters (Lens T2 rule).
public final class RopeEmbedder {
    let theta: Double
    let axesDims: [Int]
    let axesLens: [Int]
    private var cosTables: [MLXArray]?
    private var sinTables: [MLXArray]?

    public init(
        theta: Double = ZImageConfigConstants.ropeTheta,
        axesDims: [Int] = ZImageConfigConstants.ropeAxesDims,
        axesLens: [Int] = ZImageConfigConstants.ropeAxesLens
    ) {
        precondition(axesDims.count == axesLens.count)
        self.theta = theta
        self.axesDims = axesDims
        self.axesLens = axesLens
    }

    /// Reference computes freqs in float64 then casts float32 — replicate with Double host math.
    static func precomputeFreqsCisReal(
        dims: [Int], ends: [Int], theta: Double
    ) -> (cos: [MLXArray], sin: [MLXArray]) {
        var cosT: [MLXArray] = []
        var sinT: [MLXArray] = []
        for (d, e) in zip(dims, ends) {
            let half = d / 2
            var cosHost = [Float](repeating: 0, count: e * half)
            var sinHost = [Float](repeating: 0, count: e * half)
            for pos in 0..<e {
                for j in 0..<half {
                    let freq = 1.0 / pow(theta, Double(2 * j) / Double(d))
                    let angle = Float(Double(pos) * freq)  // outer() in f64, polar on f32 angles
                    cosHost[pos * half + j] = Foundation.cos(angle)
                    sinHost[pos * half + j] = Foundation.sin(angle)
                }
            }
            cosT.append(MLXArray(cosHost, [e, half]))
            sinT.append(MLXArray(sinHost, [e, half]))
        }
        return (cosT, sinT)
    }

    /// ids: [N, nAxes] Int32 → (cos, sin) each [N, sum(dims)/2].
    public func callAsFunction(_ ids: MLXArray) -> (cos: MLXArray, sin: MLXArray) {
        precondition(ids.ndim == 2 && ids.shape[1] == axesDims.count)
        if cosTables == nil {
            let t = Self.precomputeFreqsCisReal(dims: axesDims, ends: axesLens, theta: theta)
            cosTables = t.cos
            sinTables = t.sin
        }
        var cosParts: [MLXArray] = []
        var sinParts: [MLXArray] = []
        for i in 0..<axesDims.count {
            let index = ids[0..., i]
            cosParts.append(cosTables![i][index])
            sinParts.append(sinTables![i][index])
        }
        return (concatenated(cosParts, axis: -1), concatenated(sinParts, axis: -1))
    }
}

/// Per-item token metadata produced by patchify_and_embed.
struct PatchifiedItem {
    var tokens: MLXArray        // [len, dim] embedded (pads already = learned pad token)
    var posIds: [Int32]         // len * 3, row-major (axis0, h, w)
    var oriLen: Int
    var paddedLen: Int
}

public final class ZImageTransformer2DModel: Module {
    public let inChannels: Int
    public let outChannels: Int
    public let allPatchSize: [Int]
    public let allFPatchSize: [Int]
    public let dim: Int
    public let nHeads: Int
    public let ropeTheta: Double
    public let tScale: Float

    @ModuleInfo(key: "x_embedder") var xEmbedder: Linear
    @ModuleInfo(key: "final_layer") var finalLayer: FinalLayer
    @ModuleInfo(key: "noise_refiner") var noiseRefiner: [ZImageTransformerBlock]
    @ModuleInfo(key: "context_refiner") var contextRefiner: [ZImageTransformerBlock]
    @ModuleInfo(key: "t_embedder") var tEmbedder: TimestepEmbedder
    @ModuleInfo(key: "cap_embedder_norm") var capEmbedderNorm: ZImageRMSNorm
    @ModuleInfo(key: "cap_embedder_linear") var capEmbedderLinear: Linear
    @ModuleInfo(key: "x_pad_token") var xPadToken: MLXArray
    @ModuleInfo(key: "cap_pad_token") var capPadToken: MLXArray
    @ModuleInfo var layers: [ZImageTransformerBlock]

    let axesDims: [Int]
    let axesLens: [Int]
    let ropeEmbedder: RopeEmbedder

    public init(
        allPatchSize: [Int] = [2],
        allFPatchSize: [Int] = [1],
        inChannels: Int = 16,
        dim: Int = 3840,
        nLayers: Int = 30,
        nRefinerLayers: Int = 2,
        nHeads: Int = 30,
        nKVHeads: Int = 30,
        normEps: Float = 1e-5,
        qkNorm: Bool = true,
        capFeatDim: Int = 2560,
        ropeTheta: Double = ZImageConfigConstants.ropeTheta,
        tScale: Float = 1000.0,
        axesDims: [Int] = ZImageConfigConstants.ropeAxesDims,
        axesLens: [Int] = ZImageConfigConstants.ropeAxesLens
    ) {
        precondition(allPatchSize.count == allFPatchSize.count)
        precondition(allPatchSize == [2] && allFPatchSize == [1],
                     "released checkpoints ship exactly one patch config (2-1)")
        self.inChannels = inChannels
        self.outChannels = inChannels
        self.allPatchSize = allPatchSize
        self.allFPatchSize = allFPatchSize
        self.dim = dim
        self.nHeads = nHeads
        self.ropeTheta = ropeTheta
        self.tScale = tScale

        let patchSize = allPatchSize[0]
        let fPatchSize = allFPatchSize[0]
        self._xEmbedder.wrappedValue = Linear(
            fPatchSize * patchSize * patchSize * inChannels, dim, bias: true)
        self._finalLayer.wrappedValue = FinalLayer(
            hiddenSize: dim, outChannels: patchSize * patchSize * fPatchSize * inChannels)

        self._noiseRefiner.wrappedValue = (0..<nRefinerLayers).map {
            ZImageTransformerBlock(
                layerId: 1000 + $0, dim: dim, nHeads: nHeads, nKVHeads: nKVHeads,
                normEps: normEps, qkNorm: qkNorm, modulation: true)
        }
        self._contextRefiner.wrappedValue = (0..<nRefinerLayers).map {
            ZImageTransformerBlock(
                layerId: $0, dim: dim, nHeads: nHeads, nKVHeads: nKVHeads,
                normEps: normEps, qkNorm: qkNorm, modulation: false)
        }
        self._tEmbedder.wrappedValue = TimestepEmbedder(
            outSize: min(dim, ZImageConfigConstants.adalnEmbedDim), midSize: 1024)
        self._capEmbedderNorm.wrappedValue = ZImageRMSNorm(capFeatDim, eps: normEps)
        self._capEmbedderLinear.wrappedValue = Linear(capFeatDim, dim, bias: true)
        self._xPadToken.wrappedValue = zeros([1, dim])
        self._capPadToken.wrappedValue = zeros([1, dim])
        self._layers.wrappedValue = (0..<nLayers).map {
            ZImageTransformerBlock(
                layerId: $0, dim: dim, nHeads: nHeads, nKVHeads: nKVHeads,
                normEps: normEps, qkNorm: qkNorm, modulation: true)
        }

        let headDim = dim / nHeads
        precondition(headDim == axesDims.reduce(0, +))
        self.axesDims = axesDims
        self.axesLens = axesLens
        self.ropeEmbedder = RopeEmbedder(theta: ropeTheta, axesDims: axesDims, axesLens: axesLens)
    }

    func capEmbed(_ capFeats: MLXArray) -> MLXArray {
        capEmbedderLinear(capEmbedderNorm(capFeats))
    }

    /// image: [C, F, H, W] → tokens [Ft*Ht*Wt, pF*pH*pW*C] (reference axis order).
    static func patchify(_ image: MLXArray, patchSize: Int, fPatchSize: Int) -> MLXArray {
        let (C, F, H, W) = (image.shape[0], image.shape[1], image.shape[2], image.shape[3])
        let (pF, pH, pW) = (fPatchSize, patchSize, patchSize)
        let (Ft, Ht, Wt) = (F / pF, H / pH, W / pW)
        return image
            .reshaped(C, Ft, pF, Ht, pH, Wt, pW)
            .transposed(1, 3, 5, 2, 4, 6, 0)
            .reshaped(Ft * Ht * Wt, pF * pH * pW * C)
    }

    /// tokens: [len, pF*pH*pW*C] (trimmed to ori_len) → [C, F, H, W].
    func unpatchify(
        _ x: MLXArray, size: (F: Int, H: Int, W: Int), patchSize: Int, fPatchSize: Int
    ) -> MLXArray {
        let (pF, pH, pW) = (fPatchSize, patchSize, patchSize)
        let (F, H, W) = size
        let oriLen = (F / pF) * (H / pH) * (W / pW)
        return x[..<oriLen]
            .reshaped(F / pF, H / pH, W / pW, pF, pH, pW, outChannels)
            .transposed(6, 0, 3, 1, 4, 2, 5)
            .reshaped(outChannels, F, H, W)
    }

    static func coordinateGrid(size: (Int, Int, Int), start: (Int32, Int32, Int32)) -> [Int32] {
        var ids = [Int32]()
        ids.reserveCapacity(size.0 * size.1 * size.2 * 3)
        for a in 0..<size.0 {
            for b in 0..<size.1 {
                for c in 0..<size.2 {
                    ids.append(start.0 + Int32(a))
                    ids.append(start.1 + Int32(b))
                    ids.append(start.2 + Int32(c))
                }
            }
        }
        return ids
    }

    func patchifyAndEmbed(
        allImage: [MLXArray], allCapFeats: [MLXArray], patchSize: Int, fPatchSize: Int
    ) -> (x: [PatchifiedItem], cap: [PatchifiedItem], sizes: [(F: Int, H: Int, W: Int)]) {
        let multiOf = ZImageConfigConstants.seqMultiOf
        var xItems: [PatchifiedItem] = []
        var capItems: [PatchifiedItem] = []
        var sizes: [(F: Int, H: Int, W: Int)] = []

        for (image, capFeat) in zip(allImage, allCapFeats) {
            let capOriLen = capFeat.shape[0]
            let capPaddingLen = (multiOf - capOriLen % multiOf) % multiOf
            let capPaddedLen = capOriLen + capPaddingLen
            var capTokens = capEmbed(capFeat)
            if capPaddingLen > 0 {
                capTokens = concatenated(
                    [capTokens, tiled(capPadToken.asType(capTokens.dtype), repetitions: [capPaddingLen, 1])],
                    axis: 0)
            }
            let capPosIds = Self.coordinateGrid(size: (capPaddedLen, 1, 1), start: (1, 0, 0))
            capItems.append(PatchifiedItem(
                tokens: capTokens, posIds: capPosIds, oriLen: capOriLen, paddedLen: capPaddedLen))

            let (F, H, W) = (image.shape[1], image.shape[2], image.shape[3])
            sizes.append((F, H, W))
            let (Ft, Ht, Wt) = (F / fPatchSize, H / patchSize, W / patchSize)
            let patched = Self.patchify(image, patchSize: patchSize, fPatchSize: fPatchSize)
            let imageOriLen = patched.shape[0]
            let imagePaddingLen = (multiOf - imageOriLen % multiOf) % multiOf

            var imageTokens = xEmbedder(patched)
            if imagePaddingLen > 0 {
                imageTokens = concatenated(
                    [imageTokens, tiled(xPadToken.asType(imageTokens.dtype), repetitions: [imagePaddingLen, 1])],
                    axis: 0)
            }
            var imagePosIds = Self.coordinateGrid(
                size: (Ft, Ht, Wt), start: (Int32(capPaddedLen + 1), 0, 0))
            if imagePaddingLen > 0 {
                // pad positions are (0,0,0) — position 0 is reserved for padding
                imagePosIds.append(contentsOf: [Int32](repeating: 0, count: imagePaddingLen * 3))
            }
            xItems.append(PatchifiedItem(
                tokens: imageTokens, posIds: imagePosIds,
                oriLen: imageOriLen, paddedLen: imageOriLen + imagePaddingLen))
        }
        return (xItems, capItems, sizes)
    }

    /// Additive SDPA mask from per-item valid lengths ([B, 1, 1, maxLen]); nil if all-valid.
    static func additiveMask(itemLens: [Int], maxLen: Int, dtype: DType) -> MLXArray? {
        if itemLens.allSatisfy({ $0 == maxLen }) { return nil }
        var host = [Float](repeating: 0, count: itemLens.count * maxLen)
        for (i, len) in itemLens.enumerated() where len < maxLen {
            for j in len..<maxLen { host[i * maxLen + j] = -Float.infinity }
        }
        return MLXArray(host, [itemLens.count, 1, 1, maxLen]).asType(dtype)
    }

    /// Stack variable-length [len, dim] items to [B, maxLen, dim], zero-padded (pad_sequence).
    static func padSequence(_ items: [MLXArray], maxLen: Int) -> MLXArray {
        let padded = items.map { item -> MLXArray in
            let len = item.shape[0]
            if len == maxLen { return item }
            var padShape = item.shape
            padShape[0] = maxLen - len
            return concatenated([item, zeros(padShape, dtype: item.dtype)], axis: 0)
        }
        return stacked(padded, axis: 0)
    }

    /// x: per-item latents [C, F, H, W]; t: [B] (pipeline passes (1000−t)/1000);
    /// capFeats: per-item [len, 2560]. Returns per-item [C, F, H, W] predictions.
    public func callAsFunction(
        _ x: [MLXArray], t: MLXArray, capFeats: [MLXArray],
        patchSize: Int = 2, fPatchSize: Int = 1
    ) -> [MLXArray] {
        precondition(allPatchSize.contains(patchSize) && allFPatchSize.contains(fPatchSize))
        let bsz = x.count

        let tEmb = tEmbedder(t * tScale)
        let (xItems, capItems, sizes) = patchifyAndEmbed(
            allImage: x, allCapFeats: capFeats, patchSize: patchSize, fPatchSize: fPatchSize)

        let adalnInput = tEmb.asType(xItems[0].tokens.dtype)

        // --- noise refiner over image tokens ---
        let xLens = xItems.map(\.paddedLen)
        let xMaxLen = xLens.max()!
        var xTokens = Self.padSequence(xItems.map(\.tokens), maxLen: xMaxLen)
        let xRope = xItems.map { ropeEmbedder(MLXArray($0.posIds, [$0.paddedLen, 3])) }
        let xCos = Self.padSequence(xRope.map(\.cos), maxLen: xMaxLen)
        let xSin = Self.padSequence(xRope.map(\.sin), maxLen: xMaxLen)
        let xMask = Self.additiveMask(itemLens: xLens, maxLen: xMaxLen, dtype: xTokens.dtype)
        for layer in noiseRefiner {
            xTokens = layer(xTokens, attnMask: xMask, ropeCos: xCos, ropeSin: xSin,
                            adalnInput: adalnInput)
        }

        // --- context refiner over caption tokens ---
        let capLens = capItems.map(\.paddedLen)
        let capMaxLen = capLens.max()!
        var capTokens = Self.padSequence(capItems.map(\.tokens), maxLen: capMaxLen)
        let capRope = capItems.map { ropeEmbedder(MLXArray($0.posIds, [$0.paddedLen, 3])) }
        let capCos = Self.padSequence(capRope.map(\.cos), maxLen: capMaxLen)
        let capSin = Self.padSequence(capRope.map(\.sin), maxLen: capMaxLen)
        let capMask = Self.additiveMask(itemLens: capLens, maxLen: capMaxLen, dtype: capTokens.dtype)
        for layer in contextRefiner {
            capTokens = layer(capTokens, attnMask: capMask, ropeCos: capCos, ropeSin: capSin)
        }

        // --- unified = concat[image, caption] per item (image FIRST — code, not tech report) ---
        var unifiedItems: [MLXArray] = []
        var unifiedCos: [MLXArray] = []
        var unifiedSin: [MLXArray] = []
        for i in 0..<bsz {
            unifiedItems.append(concatenated(
                [xTokens[i][..<xLens[i]], capTokens[i][..<capLens[i]]], axis: 0))
            unifiedCos.append(concatenated(
                [xCos[i][..<xLens[i]], capCos[i][..<capLens[i]]], axis: 0))
            unifiedSin.append(concatenated(
                [xSin[i][..<xLens[i]], capSin[i][..<capLens[i]]], axis: 0))
        }
        let unifiedLens = zip(xLens, capLens).map(+)
        let unifiedMaxLen = unifiedLens.max()!
        var unified = Self.padSequence(unifiedItems, maxLen: unifiedMaxLen)
        let uCos = Self.padSequence(unifiedCos, maxLen: unifiedMaxLen)
        let uSin = Self.padSequence(unifiedSin, maxLen: unifiedMaxLen)
        let uMask = Self.additiveMask(itemLens: unifiedLens, maxLen: unifiedMaxLen, dtype: unified.dtype)

        for layer in layers {
            unified = layer(unified, attnMask: uMask, ropeCos: uCos, ropeSin: uSin,
                            adalnInput: adalnInput)
        }

        unified = finalLayer(unified, adalnInput)

        return (0..<bsz).map { i in
            unpatchify(unified[i], size: sizes[i], patchSize: patchSize, fPatchSize: fPatchSize)
        }
    }
}
