# seedvr2-mlx-swift

Standalone **MLX-Swift** port of **SeedVR2** (ByteDance, ICLR 2026) — one-step
diffusion-based super-resolution — for **MLXEngine** and **ForgeUpscaler** (Export tier,
peer to `OSEDiff_MLX`, alongside the already-ported `EfRLFN`). No runtime dependency on
Python/mflux.

- **Reference (oracle):** [`filipstrand/mflux`](https://github.com/filipstrand/mflux) `src/mflux/models/seedvr2/` (MLX-Python). This port is an MLX-Python → MLX-Swift translation — see `docs/PORT-PLAN.md`.
- **Model/weights license:** Apache-2.0 (ByteDance Seed). Port code: MIT.
- **Weights:** [mlx-community/SeedVR2-3B-mlx](https://huggingface.co/mlx-community/SeedVR2-3B-mlx) (fp16) · [SeedVR2-3B-mlx-int8](https://huggingface.co/mlx-community/SeedVR2-3B-mlx-int8) (near-lossless, ~4 GB on-device) · [collection](https://huggingface.co/collections/mlx-community/seedvr2-mlx-swift-6a23c38505955a29500123b4).
- **Status:** ✅ full inference path ported (`SeedVR2Upscaler.upscale`) + parity-verified vs mflux (DiT `t_out` 2.1e-4, VAE 3.5e-3/7.2e-3, RNG/scheduler 0.0, int8 cosine 0.99997) and weights published. Remaining = host preprocess/color-correct + ForgeUpscaler integration (tiling, Export-tier conformer) → **see [`docs/FORGE-HANDOFF.md`](docs/FORGE-HANDOFF.md)**. Port detail: `docs/PORT-PLAN.md`.

> CLI note: the `seedvr2-upscale` executable (`Sources/RunUpscale`) is currently a
> weight-loader smoke harness — it loads the exported weights and prints tensor counts.
> Full image-in/image-out upscaling is exercised through the library API
> (`SeedVR2Upscaler.upscale(...)`) and the parity tests; wiring the end-to-end path into the
> CLI is part of the Forge integration work.

## Build & test

```bash
# Tests MUST run via xcodebuild (the SPM CLI can't bundle the Metal default.metallib).
xcodebuild test -scheme SeedVR2MLX-Package -destination 'platform=macOS'
swift build         # library + CLI compile fine from the CLI
```

## Weights

Exported from the mflux oracle by `seedvr2-mlx/scripts/prepare_swift.py`:
`transformer.safetensors + vae.safetensors + pos_emb.safetensors + config.json`
(fp16; reload verified bit-exact vs mflux). Published as `mlx-community/SeedVR2-3B-mlx`
(fp16 + int8 — int8 is near-lossless and the on-device target; int4 degrades this model).
`SeedVR2Upscaler(repoId:)` / `SeedVR2Weights.from(repoId:)` auto-download via `HFHub`.

## Layout

```
Sources/SeedVR2MLX/
  Config.swift                        # 3B/7B dims + transformer_overrides
  Models/Transformer/
    RMSNorm.swift, RoPE.swift, SwiGLU.swift, AdaModulation.swift,
    Attention.swift, Patch.swift, TimeEmbedding.swift, Window.swift,
    TransformerBlock.swift, Transformer.swift
  Models/VAE/
    CausalConv3d.swift, VAEBlocks.swift, VAE.swift   # 3D-causal-conv VAE
  Pipeline/
    Preprocess via host; LatentCreator.swift, Scheduler.swift,
    Upscaler.swift (SeedVR2Upscaler.upscale), ColorCorrect.swift
  Utilities/
    WeightLoader.swift (load exported safetensors + config),
    HFHub.swift (HF auto-download), Quantization.swift (int8 apply-on-load)
Sources/RunUpscale/main.swift         # seedvr2-upscale CLI (weight-load smoke harness)
Tests/SeedVR2MLXTests/                # CPU parity vs goldens (xcodebuild):
  TransformerParityTests, VAEParityTests, AttentionParityTests,
  PipelineParityTests, ColorCorrectParityTests, QuantizationTests,
  LeafModuleTests, SmokeTests
docs/PORT-PLAN.md                     # full module work-list + parity gates
docs/FORGE-HANDOFF.md                 # ForgeUpscaler integration handoff
```

## Package products

- Library: `SeedVR2MLX`
- Executable: `seedvr2-upscale` (target `RunUpscale`)
- Dependencies: `ml-explore/mlx-swift` (0.31.2 ..< 0.32.0), `apple/swift-argument-parser` (1.3.0+)
- Platforms: macOS 14+, iOS 17+, visionOS 1+
