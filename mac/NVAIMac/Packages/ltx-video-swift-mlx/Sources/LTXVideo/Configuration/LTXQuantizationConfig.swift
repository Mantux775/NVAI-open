// LTXQuantizationConfig.swift - Quantization Configuration
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXNN

// MARK: - Transformer Quantization

/// Quantization options for the LTX-2 transformer.
///
/// On-the-fly quantization replaces all `Linear` layers with `QuantizedLinear`
/// after weight loading, reducing memory usage at the cost of some quality.
///
/// ## Memory estimates (LTX-2 transformer only)
/// | Option | Bits | Transformer RAM | Format |
/// |--------|------|-----------------|--------|
/// | bf16   | 16   | ~25 GB          | Full precision |
/// | qint8  | 8    | ~13 GB          | Affine integer |
/// | int4   | 4    | ~7 GB           | Affine integer |
/// | nvfp4  | 4    | ~7 GB           | NVIDIA FP4 (logarithmic, better for transformers) |
/// | mxfp8  | 8    | ~13 GB          | OCP Microscaling FP8 |
public enum TransformerQuantization: String, CaseIterable, Sendable {
    /// BFloat16 — full precision (default)
    case bf16 = "bf16"

    /// 8-bit affine quantization (qint8)
    case qint8 = "qint8"

    /// 4-bit affine quantization (int4)
    case int4 = "int4"

    /// NVIDIA FP4 — 4-bit floating point (1 sign + 2 exp + 1 mantissa).
    /// Better for transformer weights (gaussian distribution near 0).
    /// Pre-quantized weights available: `Lightricks/LTX-2.3-nvfp4`
    ///
    /// - Note: On-the-fly quantization not yet supported (upstream mlx-swift #285).
    ///   Use pre-quantized weights from HuggingFace instead.
    case nvfp4 = "nvfp4"

    /// OCP Microscaling FP8 — 8-bit floating point.
    /// Pre-quantized weights available: `Lightricks/LTX-2.3-fp8`
    ///
    /// - Note: On-the-fly quantization not yet supported (upstream mlx-swift #285).
    ///   Use pre-quantized weights from HuggingFace instead.
    case mxfp8 = "mxfp8"

    public var displayName: String {
        switch self {
        case .bf16: return "BFloat16"
        case .qint8: return "8-bit (qint8)"
        case .int4: return "4-bit (int4)"
        case .nvfp4: return "4-bit (NVFP4)"
        case .mxfp8: return "8-bit (MXFP8)"
        }
    }

    /// MLX quantization mode
    public var quantizationMode: QuantizationMode {
        switch self {
        case .bf16, .qint8, .int4: return .affine
        case .nvfp4: return .nvfp4
        case .mxfp8: return .mxfp8
        }
    }

    /// Number of bits per weight
    public var bits: Int {
        switch self {
        case .bf16: return 16
        case .qint8, .mxfp8: return 8
        case .int4, .nvfp4: return 4
        }
    }

    /// Group size for quantization
    public var groupSize: Int {
        switch self {
        case .nvfp4: return 32   // NVFP4 default
        case .mxfp8: return 32   // MXFP8 default
        default: return 64       // Affine default
        }
    }

    /// Whether on-the-fly quantization is needed
    public var needsQuantization: Bool {
        self != .bf16
    }

    /// Approximate memory reduction factor compared to bf16
    public var memoryReduction: Float {
        switch self {
        case .bf16: return 1.0
        case .qint8, .mxfp8: return 0.5
        case .int4, .nvfp4: return 0.25
        }
    }
}

// MARK: - Combined Configuration

/// Quantization configuration for the LTX-2 pipeline.
///
/// Controls on-the-fly quantization of the transformer and, for LTX-2.5, of the
/// text encoder. LTX-2.3's Gemma 3 encoder is downloaded already quantized
/// (4-bit QAT from mlx-community) and ignores `textEncoder`; LTX-2.5's Gemma 4
/// derivative is published in bf16 only, so quantizing it is the only way to
/// shrink its ~24 GB footprint.
///
/// ## Usage
/// ```swift
/// // Default: full precision
/// let pipeline = LTXPipeline(model: .distilled)
///
/// // Memory-efficient: 8-bit transformer
/// let pipeline = LTXPipeline(
///     model: .distilled,
///     quantization: LTXQuantizationConfig(transformer: .qint8)
/// )
///
/// // Ultra-minimal: 4-bit transformer
/// let pipeline = LTXPipeline(
///     model: .distilled,
///     quantization: .minimal
/// )
/// ```
/// Mixed precision configuration for per-block quantization.
///
/// First and last blocks of the transformer are more sensitive to quantization
/// (they control global structure and fine detail). Middle blocks can be quantized
/// more aggressively with minimal quality loss.
///
/// Based on Q-DiT (CVPR 2025) and ViDiT-Q (ICLR 2025) findings.
public struct MixedPrecisionConfig: Sendable {
    /// Block indices to keep at higher precision
    public var highPrecisionBlocks: Set<Int>

    /// Bits for high-precision blocks (8 = qint8, 16 = bf16)
    public var highPrecisionBits: Int

    /// Bits for remaining blocks (4 = int4)
    public var lowPrecisionBits: Int

    /// Group size for quantization
    public var groupSize: Int

    public init(
        highPrecisionBlocks: Set<Int>,
        highPrecisionBits: Int = 8,
        lowPrecisionBits: Int = 4,
        groupSize: Int = 64
    ) {
        self.highPrecisionBlocks = highPrecisionBlocks
        self.highPrecisionBits = highPrecisionBits
        self.lowPrecisionBits = lowPrecisionBits
        self.groupSize = groupSize
    }

    /// Default: first 6 + last 6 blocks in qint8, rest in int4
    /// For 48-block LTX-2.3 transformer
    public static let `default` = MixedPrecisionConfig(
        highPrecisionBlocks: Set(0...5).union(Set(42...47)),
        highPrecisionBits: 8,
        lowPrecisionBits: 4
    )

    /// Conservative: first 8 + last 8 in qint8, rest in int4
    public static let conservative = MixedPrecisionConfig(
        highPrecisionBlocks: Set(0...7).union(Set(40...47)),
        highPrecisionBits: 8,
        lowPrecisionBits: 4
    )

    /// Aggressive: only first 4 + last 4 in qint8, rest in int4
    public static let aggressive = MixedPrecisionConfig(
        highPrecisionBlocks: Set(0...3).union(Set(44...47)),
        highPrecisionBits: 8,
        lowPrecisionBits: 4
    )

    /// Estimated memory in GB for the transformer (48-block LTX-2.3 22B)
    public var estimatedTransformerGB: Float {
        let totalBlocks = 48
        let highCount = highPrecisionBlocks.filter { $0 < totalBlocks }.count
        let lowCount = totalBlocks - highCount
        // Each block is ~460MB in bf16
        let blockSizeBF16: Float = 0.46
        let highSize = Float(highCount) * blockSizeBF16 * (Float(highPrecisionBits) / 16.0)
        let lowSize = Float(lowCount) * blockSizeBF16 * (Float(lowPrecisionBits) / 16.0)
        // Add ~2GB for non-block params (embeddings, projections)
        return highSize + lowSize + 2.0
    }
}

public struct LTXQuantizationConfig: Sendable {
    /// Transformer quantization level (uniform across all blocks)
    public var transformer: TransformerQuantization

    /// Mixed precision: per-block quantization (overrides `transformer` when set)
    public var mixedPrecision: MixedPrecisionConfig?

    /// Text-encoder quantization, applied on the fly after loading.
    ///
    /// Only meaningful for LTX-2.5: its Gemma 4 encoder is a checkpoint-specific
    /// derivative published in bf16 only (~24 GB resident), so quantizing is the
    /// sole way to shrink it. LTX-2.3 ignores this — its Gemma 3 encoder is
    /// downloaded already quantized (4-bit QAT).
    public var textEncoder: TransformerQuantization

    public init(
        transformer: TransformerQuantization = .bf16,
        mixedPrecision: MixedPrecisionConfig? = nil,
        textEncoder: TransformerQuantization = .bf16
    ) {
        self.transformer = transformer
        self.mixedPrecision = mixedPrecision
        self.textEncoder = textEncoder
    }

    // MARK: - Presets

    /// Default: full precision bf16 (no quantization)
    public static let `default` = LTXQuantizationConfig(transformer: .bf16)

    /// Memory-efficient: 8-bit transformer (~50% memory reduction)
    public static let memoryEfficient = LTXQuantizationConfig(
        transformer: .qint8, textEncoder: .qint8)

    /// Minimal memory: 4-bit transformer (~75% memory reduction)
    public static let minimal = LTXQuantizationConfig(
        transformer: .int4, textEncoder: .int4)

    /// Mixed precision: first/last blocks qint8, middle blocks int4 (~60% reduction)
    public static let mixedDefault = LTXQuantizationConfig(
        transformer: .bf16, mixedPrecision: .default
    )
}

extension LTXQuantizationConfig: CustomStringConvertible {
    public var description: String {
        "LTXQuantizationConfig(transformer: \(transformer.displayName), "
            + "textEncoder: \(textEncoder.displayName))"
    }
}
