// LTXModelCatalog.swift - Licensing, gating and checkpoint layout metadata
// Copyright 2025
//
// Everything a caller needs to decide *whether* it may download and use a
// checkpoint — before it spends 40+ GB of bandwidth on it. Modelled on the
// flux-2-swift-mlx registry: every downloadable artefact carries its licence,
// its gating status and its HuggingFace URL, so an app can show the licence
// and route the user to the "Agree and Access" page instead of failing with a
// bare 403 halfway through a download.

import Foundation

// MARK: - License

/// Licence attached to a downloadable model artefact.
///
/// `allowsCommercialUse` answers the coarse question "may this ship in a paid
/// product at all"; `summary` carries the conditions that a UI must surface
/// (revenue thresholds, redistribution limits). Neither replaces reading
/// `url` — they exist so an app can present the terms before downloading.
public struct LTXLicense: Sendable, Equatable, Hashable {
    /// Stable identifier, usable as a dictionary key or in serialized state.
    public let id: String

    /// Human-readable licence name, for display next to a model.
    public let name: String

    /// Canonical URL of the full, binding licence text.
    public let url: String

    /// Whether the licence permits commercial use at all (possibly under conditions —
    /// see ``summary``).
    public let allowsCommercialUse: Bool

    /// One-paragraph description of the conditions that matter in practice.
    public let summary: String

    public init(id: String, name: String, url: String, allowsCommercialUse: Bool, summary: String) {
        self.id = id
        self.name = name
        self.url = url
        self.allowsCommercialUse = allowsCommercialUse
        self.summary = summary
    }

    /// LTX-2.x Community License — covers every Lightricks LTX-2 / 2.3 / 2.5 weight,
    /// including the IC-LoRAs and upscalers published alongside them.
    public static let ltx2Community = LTXLicense(
        id: "ltx-2-community",
        name: "LTX-2.x Community License",
        url: "https://github.com/Lightricks/LTX-2/blob/main/LICENSE.md",
        allowsCommercialUse: true,
        summary: """
            Free for commercial and production use for entities under $10M annual revenue \
            (measured entity-wide, including subsidiaries and affiliates under common control). \
            Above that threshold a paid Commercial Use Agreement with Lightricks is required. \
            Transferring fine-tunes may itself require a paid licence.
            """
    )

    /// Google Gemma Terms of Use — covers the Gemma text encoder weights, whether
    /// pulled from `mlx-community` (LTX-2.3) or bundled inside the LTX checkpoint
    /// (LTX-2.5 ships a Gemma 4 12B derivative).
    public static let gemmaTerms = LTXLicense(
        id: "gemma-terms-of-use",
        name: "Gemma Terms of Use",
        url: "https://ai.google.dev/gemma/terms",
        allowsCommercialUse: true,
        summary: """
            Commercial use permitted subject to Google's use restrictions; redistribution must \
            carry the same terms and the prohibited-use policy.
            """
    )
}

// MARK: - Gating

/// How a repository restricts downloads.
public enum LTXGating: Sendable, Equatable {
    /// Public repository — no token required.
    case open

    /// Gated: the account must accept the licence on HuggingFace, and requests must
    /// carry a token for that account.
    case licenseAcceptanceRequired

    /// Whether a HuggingFace token is required to download.
    public var requiresToken: Bool { self == .licenseAcceptanceRequired }
}

// MARK: - Implementation status

/// Whether this Swift package can actually *run* a checkpoint today.
///
/// Kept separate from licensing so the model list can advertise a checkpoint
/// (with its licence and download URL) while being honest that the pipeline
/// does not execute it yet.
public enum LTXModelSupport: Sendable, Equatable {
    /// Fully implemented: inference runs end to end.
    case supported

    /// Catalogued but not runnable yet; the string explains what is missing.
    case notImplemented(String)

    public var isRunnable: Bool { self == .supported }

    public var label: String {
        switch self {
        case .supported: return "ready"
        case .notImplemented: return "catalog"
        }
    }
}

// MARK: - Text encoder requirement

/// Which text-encoder stack a checkpoint's transformer was trained against.
///
/// A mismatch here is not a soft-quality issue: the connector consumes a
/// concatenation of *every* Gemma hidden state, so a different Gemma root
/// produces a differently-shaped and differently-distributed feature vector.
/// LTX's own loader refuses the pairing outright (`gemma_source_checkpoint`).
public enum LTXTextEncoderRequirement: String, Sendable, CaseIterable {
    /// Gemma 3 12B IT — stock Google checkpoint, sourced from `mlx-community` in 4-bit QAT.
    case gemma3_12b = "gemma-3-12b-it"

    /// Gemma 4 12B, LTX-specific derivative (`gemma4-12b-ltx-v1`), shipped inside the
    /// LTX-2.5 text-encoder safetensors together with the LTX projections.
    case gemma4_12bLTX = "gemma4-12b-ltx-v1"

    public var displayName: String {
        switch self {
        case .gemma3_12b: return "Gemma 3 12B (mlx-community, 4-bit QAT)"
        case .gemma4_12bLTX: return "Gemma 4 12B LTX (bundled with the checkpoint)"
        }
    }

    /// HuggingFace repo the encoder weights come from, when they are external.
    /// `nil` means the weights ship inside the LTX checkpoint itself.
    public var externalRepo: String? {
        switch self {
        case .gemma3_12b: return "mlx-community/gemma-3-12b-it-qat-4bit"
        case .gemma4_12bLTX: return nil
        }
    }
}

// MARK: - Checkpoint layout

/// How a model generation packages its weights on HuggingFace.
public enum LTXWeightsLayout: Sendable, Equatable {
    /// One safetensors file holding transformer + connectors + video VAE + audio VAE + vocoder.
    /// Used by LTX-2.3.
    case unified

    /// One safetensors file per component (Comfy-aligned). Used by LTX-2.5.
    case split
}

// MARK: - Model family

/// A generation of LTX checkpoints. Licensing, gating and packaging are
/// properties of the generation, not of the individual dev/distilled variant.
public enum LTXModelFamily: String, CaseIterable, Sendable {
    case ltx23 = "2.3"
    case ltx25 = "2.5"

    public var displayName: String { "LTX-\(rawValue)" }

    /// HuggingFace repository hosting the checkpoints of this generation.
    public var huggingFaceRepo: String {
        switch self {
        case .ltx23: return "Lightricks/LTX-2.3"
        case .ltx25: return "Lightricks/LTX-2.5"
        }
    }

    public var huggingFaceURL: String { "https://huggingface.co/\(huggingFaceRepo)" }

    /// LTX-2.5 repositories are gated: the account must click "Agree and Access"
    /// on the model page, and downloads must carry that account's token.
    public var gating: LTXGating {
        switch self {
        case .ltx23: return .open
        case .ltx25: return .licenseAcceptanceRequired
        }
    }

    public var license: LTXLicense { .ltx2Community }

    public var weightsLayout: LTXWeightsLayout {
        switch self {
        case .ltx23: return .unified
        case .ltx25: return .split
        }
    }

    public var textEncoder: LTXTextEncoderRequirement {
        switch self {
        case .ltx23: return .gemma3_12b
        case .ltx25: return .gemma4_12bLTX
        }
    }

    /// `model_version` string stamped in the checkpoint's safetensors metadata.
    /// Used to verify that a local file is what the catalog claims it is.
    public var checkpointModelVersion: String {
        switch self {
        case .ltx23: return "2.3.0"
        case .ltx25: return "2.5.0"
        }
    }

    /// Shared (non-transformer) component files, for split layouts.
    /// Empty for unified layouts, where these live inside the single file.
    public var sharedComponentFiles: [LTXComponentFile] {
        switch self {
        case .ltx23:
            return []
        case .ltx25:
            return [
                LTXComponentFile(
                    kind: .textEncoder,
                    path: "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
                    sizeGB: 26.3),
                LTXComponentFile(
                    kind: .videoVAE,
                    path: "vae/ltx-2.5-video-vae-conv-bf16.safetensors",
                    sizeGB: 1.45),
                LTXComponentFile(
                    kind: .diffusionVideoVAE,
                    path: "vae/ltx-2.5-video-vae-bf16.safetensors",
                    sizeGB: 1.47),
                LTXComponentFile(
                    kind: .audioVAE,
                    path: "vae/ltx-2.5-audio-vae-bf16.safetensors",
                    sizeGB: 0.36),
                LTXComponentFile(
                    kind: .durationHead,
                    path: "model_patches/ltx-2.5-duration-head-bf16.safetensors",
                    sizeGB: 0.004),
            ]
        }
    }
}

/// One downloadable file inside a split checkpoint.
public struct LTXComponentFile: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case transformer
        case textEncoder
        /// Convolutional video VAE — the decoder this package implements.
        case videoVAE
        /// Diffusion video decoder (LTX-2.5 "DiffVAE") — opt-in, see `loadDiffusionDecoder()`.
        case diffusionVideoVAE
        case audioVAE
        /// Optional caption-conditioned clip-length predictor (LTX-2.5).
        case durationHead
    }

    public let kind: Kind
    /// Path of the file inside the HuggingFace repository.
    public let path: String
    /// Approximate download size in GB.
    public let sizeGB: Float

    public init(kind: Kind, path: String, sizeGB: Float) {
        self.kind = kind
        self.path = path
        self.sizeGB = sizeGB
    }

    /// Basename, used as the on-disk filename.
    public var filename: String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Auxiliary models

/// Upscalers, LoRAs and model patches that are downloaded separately from the
/// main checkpoint. Each carries its own repository, gating and licence — the
/// LTX-2.5 pixel upscaler lives in a gated repo of its own, distinct from the
/// (also gated) LTX-2.5 base repo.
public enum LTXAuxiliaryModel: String, CaseIterable, Sendable {
    /// LTX-2.3 latent spatial upscaler ×2, used by the two-stage HQ pipeline.
    ///
    /// A standalone convolutional model that upscales **latents** between stages —
    /// not to be confused with the pixel upscaler below, which is an IC-LoRA over
    /// the transformer. They share a name and nothing else.
    case spatialUpscalerX2_23 = "latent-spatial-upscaler-x2-2.3"

    /// LTX-2.5 latent spatial upscaler ×2.
    case latentSpatialUpscalerX2_25 = "latent-spatial-upscaler-x2-2.5"

    /// LTX-2.5 latent temporal upscaler ×2 (frame-rate doubling stage of the DFR pipeline).
    case latentTemporalUpscalerX2_25 = "latent-temporal-upscaler-x2-2.5"

    /// LTX-2.3 pixel-space spatial upscaler ×2 (IC-LoRA over the 22B transformer).
    case pixelSpatialUpscalerX2_23 = "pixel-spatial-upscaler-x2-2.3"

    /// LTX-2.3 pixel-space spatial upscaler ×4.
    case pixelSpatialUpscalerX4_23 = "pixel-spatial-upscaler-x4-2.3"

    /// LTX-2.5 pixel-space spatial upscaler, shipped as an IC-LoRA over the 22B transformer.
    case pixelSpatialUpscalerX2_25 = "pixel-spatial-upscaler-x2-2.5"

    /// LTX-2.3 distilled LoRA (rank 384), applied to the dev transformer.
    case distilledLoRA_23 = "distilled-lora-384-2.3"

    /// LTX-2.5 distilled LoRA (rank 450), applied to the dev transformer.
    case distilledLoRA_25 = "distilled-lora-450-2.5"

    /// Dub-It IC-LoRA (formerly published as "LipDub") — lip-sync dubbing.
    case dubItLoRA_23 = "dubit-ic-lora-2.3"

    public var displayName: String {
        switch self {
        case .spatialUpscalerX2_23: return "LTX-2.3 latent spatial upscaler ×2"
        case .pixelSpatialUpscalerX2_23: return "LTX-2.3 pixel spatial upscaler ×2 (IC-LoRA)"
        case .pixelSpatialUpscalerX4_23: return "LTX-2.3 pixel spatial upscaler ×4 (IC-LoRA)"
        case .latentSpatialUpscalerX2_25: return "LTX-2.5 latent spatial upscaler ×2"
        case .latentTemporalUpscalerX2_25: return "LTX-2.5 latent temporal upscaler ×2"
        case .pixelSpatialUpscalerX2_25: return "LTX-2.5 pixel spatial upscaler ×2 (IC-LoRA)"
        case .distilledLoRA_23: return "LTX-2.3 distilled LoRA (rank 384)"
        case .distilledLoRA_25: return "LTX-2.5 distilled LoRA (rank 450)"
        case .dubItLoRA_23: return "LTX-2.3 Dub-It IC-LoRA"
        }
    }

    public var family: LTXModelFamily {
        switch self {
        case .spatialUpscalerX2_23, .distilledLoRA_23, .dubItLoRA_23,
             .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23:
            return .ltx23
        case .latentSpatialUpscalerX2_25, .latentTemporalUpscalerX2_25,
             .pixelSpatialUpscalerX2_25, .distilledLoRA_25:
            return .ltx25
        }
    }

    public var huggingFaceRepo: String {
        switch self {
        case .spatialUpscalerX2_23, .distilledLoRA_23:
            return "Lightricks/LTX-2.3"
        case .dubItLoRA_23:
            // Renamed from `LTX-2.3-22b-IC-LoRA-LipDub` in August 2026; the old
            // repo id 307-redirects but its old filename is gone.
            return "Lightricks/LTX-2.3-22b-IC-LoRA-DubIt"
        case .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23:
            return "Lightricks/LTX-2.3-22b-IC-LoRA-Pixel-Spatial-Upscaler"
        case .latentSpatialUpscalerX2_25, .latentTemporalUpscalerX2_25, .distilledLoRA_25:
            return "Lightricks/LTX-2.5"
        case .pixelSpatialUpscalerX2_25:
            return "Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler"
        }
    }

    /// Path of the weights file inside its repository.
    public var filePath: String {
        switch self {
        case .spatialUpscalerX2_23:
            // 1.0 was withdrawn from the repo; 1.1 is the published revision.
            return "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
        case .distilledLoRA_23:
            return "ltx-2.3-22b-distilled-lora-384.safetensors"
        case .dubItLoRA_23:
            return "ltx-2.3-22b-ic-lora-dubit-0.9.safetensors"
        case .pixelSpatialUpscalerX2_23:
            return "ltx-2.3-22b-ic-lora-pixel-spatial-upscaler-x2-0.9.safetensors"
        case .pixelSpatialUpscalerX4_23:
            return "ltx-2.3-22b-ic-lora-pixel-spatial-upscaler-x4-0.9.safetensors"
        case .latentSpatialUpscalerX2_25:
            return "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
        case .latentTemporalUpscalerX2_25:
            return "latent_upscale_models/ltx-2.5-latent-temporal-upscaler-x2-bf16-1.0.safetensors"
        case .distilledLoRA_25:
            return "loras/ltx-2.5-22b-distilled-lora-450-bf16.safetensors"
        case .pixelSpatialUpscalerX2_25:
            return "ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
        }
    }

    public var filename: String { (filePath as NSString).lastPathComponent }

    /// Cache subdirectory name under the models directory.
    public var cacheDirectoryName: String {
        switch self {
        case .spatialUpscalerX2_23: return "ltx-upscaler"
        case .pixelSpatialUpscalerX2_23: return "ltx23-lora-pixel-upscaler-x2"
        case .pixelSpatialUpscalerX4_23: return "ltx23-lora-pixel-upscaler-x4"
        case .latentSpatialUpscalerX2_25: return "ltx25-latent-upscaler-spatial"
        case .latentTemporalUpscalerX2_25: return "ltx25-latent-upscaler-temporal"
        case .pixelSpatialUpscalerX2_25: return "ltx25-lora-pixel-upscaler"
        case .distilledLoRA_23: return "ltx-lora"
        case .distilledLoRA_25: return "ltx25-lora-distilled"
        case .dubItLoRA_23: return "ltx-lora-lipdub"
        }
    }

    public var approximateSizeGB: Float {
        switch self {
        case .spatialUpscalerX2_23, .latentSpatialUpscalerX2_25: return 1.0
        case .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23: return 0.33
        case .latentTemporalUpscalerX2_25: return 0.26
        case .pixelSpatialUpscalerX2_25: return 0.33
        case .distilledLoRA_23: return 7.6
        case .distilledLoRA_25: return 8.9
        case .dubItLoRA_23: return 1.2
        }
    }

    /// Repo-level gating. Note the IC-LoRA repositories are gated even for the
    /// 2.3 generation, whose base checkpoint repo is open.
    public var gating: LTXGating {
        switch self {
        case .spatialUpscalerX2_23, .distilledLoRA_23:
            return .open
        case .dubItLoRA_23, .pixelSpatialUpscalerX2_25,
             .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23,
             .latentSpatialUpscalerX2_25, .latentTemporalUpscalerX2_25, .distilledLoRA_25:
            return .licenseAcceptanceRequired
        }
    }

    public var license: LTXLicense { .ltx2Community }

    public var huggingFaceURL: String { "https://huggingface.co/\(huggingFaceRepo)" }

    /// Whether the artefact is an adapter to fuse into the transformer.
    ///
    /// The two upscaler families share a name and nothing else: the *latent* one
    /// is a standalone convolutional model that runs between the two stages of a
    /// generation, the *pixel* one is an IC-LoRA that re-renders from a reference
    /// video. Handing one to the other's code path is a category error, so the
    /// distinction is answerable rather than implied by the case name.
    public var isAdapter: Bool {
        switch self {
        case .spatialUpscalerX2_23, .latentSpatialUpscalerX2_25, .latentTemporalUpscalerX2_25:
            return false
        case .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23, .pixelSpatialUpscalerX2_25,
             .distilledLoRA_23, .distilledLoRA_25, .dubItLoRA_23:
            return true
        }
    }

    /// The pixel upscaler matching a generation, for callers that want to re-render
    /// rather than refine.
    public static func pixelSpatialUpscaler(for family: LTXModelFamily) -> LTXAuxiliaryModel {
        switch family {
        case .ltx23: return .pixelSpatialUpscalerX2_23
        case .ltx25: return .pixelSpatialUpscalerX2_25
        }
    }

    /// Whether this package can use the artefact today.
    public var support: LTXModelSupport {
        switch self {
        case .spatialUpscalerX2_23, .distilledLoRA_23, .dubItLoRA_23,
             .pixelSpatialUpscalerX2_23, .pixelSpatialUpscalerX4_23:
            return .supported
        case .latentSpatialUpscalerX2_25, .pixelSpatialUpscalerX2_25, .distilledLoRA_25:
            // Exercised by the shipped pipelines: the latent upscaler runs
            // between the two stages, the pixel IC-LoRA drives `upscale`, and
            // the distilled LoRA fuses onto the dev checkpoint.
            return .supported
        case .latentTemporalUpscalerX2_25:
            return .supported
        }
    }
}

// MARK: - LTXModel licensing surface

extension LTXModel {
    /// Checkpoint generation this variant belongs to.
    public var family: LTXModelFamily {
        switch self {
        case .distilled, .dev: return .ltx23
        case .v25Distilled, .v25Dev: return .ltx25
        }
    }

    /// Gating of the repository hosting this checkpoint.
    public var gating: LTXGating { family.gating }

    /// Full licence record. Prefer this over the legacy ``license`` string.
    public var licenseInfo: LTXLicense { family.license }

    /// Human-readable licence name.
    public var licenseName: String { licenseInfo.name }

    /// URL of the binding licence text.
    public var licenseURL: String { licenseInfo.url }

    /// Conditions attached to commercial use, for display in a UI.
    public var commercialUseSummary: String { licenseInfo.summary }

    /// Model page on HuggingFace — where a gated licence is accepted.
    public var huggingFaceURL: String { family.huggingFaceURL }

    /// How this generation packages its weights.
    public var weightsLayout: LTXWeightsLayout { family.weightsLayout }

    /// Text-encoder stack this checkpoint was trained against. Pairing a
    /// checkpoint with the wrong Gemma root produces garbage, not degraded output.
    public var textEncoder: LTXTextEncoderRequirement { family.textEncoder }

    /// Whether the pipeline can run this checkpoint today.
    ///
    /// All four variants run: LTX-2.5 covers t2v/i2v, audio, auto-duration and
    /// the two-stage upscale chain. Not implemented for any generation: the
    /// diffusion video decoder (the conv decoder is loaded instead) and the
    /// temporal upscaler. `validateRunnable()` is the API's stable refusal
    /// point should a future catalogued-only checkpoint land.
    public var support: LTXModelSupport {
        .supported
    }

    /// Every file that must be downloaded to run this checkpoint, excluding the
    /// external text encoder (LTX-2.3) which is fetched from `mlx-community`.
    public var componentFiles: [LTXComponentFile] {
        switch weightsLayout {
        case .unified:
            return [LTXComponentFile(
                kind: .transformer,
                path: unifiedWeightsFilename,
                sizeGB: estimatedSizeGB)]
        case .split:
            return [LTXComponentFile(
                kind: .transformer,
                path: unifiedWeightsFilename,
                sizeGB: 42.0)] + family.sharedComponentFiles
        }
    }

    /// The default spatial upscaler for this generation's two-stage pipeline.
    public var defaultSpatialUpscaler: LTXAuxiliaryModel {
        switch family {
        case .ltx23: return .spatialUpscalerX2_23
        case .ltx25: return .latentSpatialUpscalerX2_25
        }
    }

    /// The distilled LoRA matching this generation, applied on top of a dev transformer.
    public var matchingDistilledLoRA: LTXAuxiliaryModel {
        switch family {
        case .ltx23: return .distilledLoRA_23
        case .ltx25: return .distilledLoRA_25
        }
    }

    /// Throw a descriptive error when a caller asks the pipeline to run a
    /// checkpoint this package only catalogs.
    ///
    /// Call this at the entry point of any operation that loads weights, so an
    /// unsupported selection fails immediately with an explanation rather than
    /// after a 40 GB download or with a wall of unmatched weight keys.
    public func validateRunnable() throws {
        if case .notImplemented(let reason) = support {
            throw LTXError.invalidConfiguration(
                "\(displayName) is not runnable by this package yet: \(reason). "
                + "Supported variants: "
                + LTXModel.allCases.filter { $0.support.isRunnable }
                    .map(\.rawValue).joined(separator: ", "))
        }
    }
}
