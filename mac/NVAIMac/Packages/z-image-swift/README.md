# z-image-swift

Swift/MLX port of Alibaba Tongyi's **[Z-Image](https://github.com/Tongyi-MAI/Z-Image)**
(Apache-2.0): a 6.15B single-stream **S3-DiT** text-to-image model — Qwen3-4B thinking-template
conditioning (`hidden_states[-2]`) → single-stream DiT → FLUX.1-dev AE decode. Ships MLXEngine's
**`textToImage`** capability in two tiers.

Two products:
- **`ZImage`** — the engine-agnostic generator core (DiT + FLUX.1 AE + Qwen3-4B encoder +
  FlowMatchEuler scheduler + pipeline).
- **`MLXZImage`** — the conformant MLXEngine wrappers: `ZImageT2IPackage` (Base, ~28-step CFG,
  surface `z-image-t2i`) and `ZImageTurboT2IPackage` (Turbo, distilled 8-step no-CFG, surface
  `z-image-turbo-t2i`), both `textToImage`, selected by `PackageID`.

> **Status: complete · wrapped · GPU-validated.** Parity vs the PyTorch goldens (fp32/CPU stream):
> DiT cosine **≥0.9999999** (both aligned + padded cases) · VAE decode **118 dB** · encoder token
> ids **exact** + features cosine **1.0000000** · full-pipeline e2e **105–108 dB** (256²/CPU).
> GPU bf16 1024²/8-step Turbo renders a sharp, prompt-faithful image in **~13 s**. Output is capped
> at 1536² by area, and the declared footprint covers it: int4 11.9 + 28.0 GB (see "Output-size cap"). Base + CFG (guidance 4.0, negative prompt) parity-locked at
> cosine 1.000000. Resolution sweep 512²/1024²/1536² all coherent. Quant: **int8** DiT 6.4 GB
> (cos 0.9998), **int4** DiT 3.5 GB (renders sharp). Wrapped as two `textToImage` ModelPackages,
> validated through the real `load → run → decode` surface — the third public T2I backer alongside
> Lens and ERNIE-Image (co-resident, selectable by PackageID).

## Consuming it

Public + version-tagged on github.com/xocialize — add by tagged URL:
`.package(url: "https://github.com/xocialize/z-image-swift", from: "0.1.0")`, then import
`MLXZImage` (the conformant packages) or `ZImage` (the bare generator).

```swift
import MLXZImage
import MLXToolKit

// Turbo tier (fast, 8-step no-CFG). quant: .int4 → ~6 GB pipeline (16 GB Mac); .bf16 → ~20 GB.
let package = ZImageTurboT2IPackage(configuration: .turbo(
    quant: .int4,
    snapshotPath: "<root>/Z-Image-Turbo"))   // or nil → auto-materialize from mlx-community
try await package.load()
let response = try await package.run(T2IRequest(
    prompt: "a lighthouse on a stormy coast at dusk, photorealistic",
    width: 1024, height: 1024, seed: 42)) as! T2IResponse
// response.image: canonical Image (.png)
await package.unload()
```

Base tier: `ZImageT2IPackage(configuration: .base(quant: .bf16, snapshotPath: ...))` — non-distilled,
~28-step with CFG + negative prompts; the quality / LoRA-substrate tier.

**Image-to-image (v0.2.2):** both tiers also expose an `imageEdit` surface — re-generate from an
input image conditioned on a prompt. `metaData["strength"]` (0–1, **default 0.75**) controls how much
of the input is preserved vs redrawn. Encode → renoise at the strength-picked sigma → denoise. As a
rough guide: **~0.5** relight/restyle (holds everything), **~0.75** visible edit + composition kept
(the default), **~0.9** new environment / time-of-day swaps (subject also redraws — e.g. day→night).

> **v0.2.1 fix + v0.2.2 default:** the `strength → t_start` step count floors the *difference* exactly
> like diffusers (`int(steps − steps·strength)`), not the product — the prior off-by-one started one
> denoise step late, so edits came back near-identity on the distilled 8-step Turbo. v0.2.2 also raises
> the default strength from diffusers' 0.6 to **0.75**: on Turbo, 0.6 barely moves global edits (the
> preserved low-frequency content wins), while 0.75 gives a visible edit on most prompts and still
> holds composition.

```swift
let out = try await package.run(IEditRequest(
    images: [inputImage], prompt: "...in an oil-painting style",
    metaData: ["strength": .double(0.9)]))  // omit for the 0.75 default; raise for scene swaps
    as! IEditResponse
```

## Run-phase progress (v0.5.4, AB-A-0139)

The packages report into the engine's `RunProgress` plane (contract 1.18.0), so a host shows
`denoise 5/8` instead of an unexplained "running". The phases, in order:

| phase | covers | steps? |
|---|---|---|
| `encode` | Qwen3-4B conditioning (plus the negative pass under CFG on base), and the AE encode of the input image on img2img | no |
| `denoise` | the flow-matching Euler loop: once at loop entry with no step, then after each completed step. `N` counts the forwards that run, so img2img at strength 0.75 over 8 steps reports 1/6 … 6/6 | **yes** — `step i/N`, 1-based |
| `decode` | FLUX.1 AE decode — one eval, so no per-chunk counts | no |
| `postprocess` | PNG encode (reported by the wrapper, after the model is done) | no |

Measured with `zimage-cli --pkg-e2e turbo --width 768` (bf16, Apple M5 Max), which binds a
print sink around `run()` the way the engine does:

```
encode 1.17 s → denoise 1/8 at +3.50 s (first step carries the warm-up) … 8/8 at +8.23 s
(≈0.66 s/step) → decode 2.77 s → postprocess 0.07 s        (11.07 s run)
```

The core stays engine-free: `ZImage` reports into its own `ZImageProgress` task-local sink, and
`MLXZImage` forwards those events into `RunProgress` (`ZImageProgressBridge`). Nothing bound ⇒ no-op, so the
CLI and the parity gates run unchanged. A host binds a sink around `engine.run` (contract 1.51.0)
or reads `engine.runProgress`.

## Weights

Published bf16 snapshots on Hugging Face (Apache-2.0), materialized automatically by the engine
(`WeightSourcing`) or pointed at via `snapshotPath`:
- Turbo: [`mlx-community/Z-Image-Turbo-bf16`](https://huggingface.co/mlx-community/Z-Image-Turbo-bf16)
- Base: [`mlx-community/Z-Image-bf16`](https://huggingface.co/mlx-community/Z-Image-bf16)

int8/int4 are produced at load time from the bf16 snapshot (correct resident footprint;
pre-quantized repos are a later download-size optimization), so every quant tier downloads the bf16
repo. Before v0.5.3 the int8/int4 tiers named `-8bit`/`-4bit` repos that were never published, and
their first download failed with HTTP 404 (AB-T-0221). Upstream:
[Tongyi-MAI/Z-Image-Turbo](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo) ·
[Tongyi-MAI/Z-Image](https://huggingface.co/Tongyi-MAI/Z-Image).

## Architecture notes (S3-DiT)

- Single stream: image VAE tokens + caption tokens concatenated (image first) through 2 noise-refiner
  + 2 context-refiner blocks, then 30 main blocks. Scale-only tanh-gated AdaLN (256-dim embed),
  SwiGLU FFN, QK-RMSNorm, 3-axis RoPE (θ=256, axes 32/48/48).
- Text encoder = Qwen3-4B, penultimate hidden state via the thinking-mode chat template.
- VAE = FLUX.1-dev AE (16 latent channels, `scaling 0.3611 / shift 0.1159`, force-upcast fp32 decode).
- Turbo: distilled 8-step, guidance 0 (no CFG), scheduler static shift 3.0. Base: ~28-step CFG,
  shift 6.0. **Turbo has low seed variance — a model trait, not a bug** (Base is the diverse/LoRA tier).

## Gates

- Always-on: `swift test --filter P1MathTests` (scheduler + RoPE) and `--filter MLXZImageTests`
  (offline MAT + conformance, no weights).
- Parity/GPU gates need the weights + goldens: `ZIMAGE_PARITY=1 swift test` (fp32/CPU), and the
  GPU lane via `swift run -c release zimage-cli` (`--quant-gate 8,4`, `--pkg-e2e turbo --quant 4`, …).
- VAE GPU lane: `swift test --filter WinogradProbeTests` is weight-free. `ZIMAGE_PARITY=1
  ZIMAGE_SNAPSHOT=<Z-Image-Turbo> swift test -c release -Xswiftc -enable-testing --filter
  P3bVAEGPULaneTests` compares both lanes (see below).

## Decode memory (2026-10-07, AB-L-0176 audit)

The AE decoder now evaluates the mid block and each up block before the next (`VAEDecoder.stageEval`).
Values are unchanged (max|Δ| 0 at every size, byte-identical package PNGs).

As one lazy graph, the up path held more live intermediates than it needed. That up path, not the mid
attention's (h·w)² fp32 score matrix, is this decoder's peak. Chunking the attention's queries (the
AB-L-0176 fix for Wan/Qwen-Image VAEs) was measured, bit-identical, and saved nothing:
- 2048²: 59.1 → 60.2 GB without stage evals, and 47.1 → 49.3 GB with them.

The up path cannot be halo-tiled exactly either, because its GroupNorms take whole-frame statistics.

| fp32 decode, GPU (M5 Max), MLX transient | v0.5.0 (one graph) | v0.5.1 (stage eval) |
|---|---|---|
| 1024² | 15.08 GB | 12.33 GB |
| 1536² | 33.80 GB | 27.67 GB |
| 2048² | 59.12 GB | 47.13 GB |
| 1440×2560 | 51.87 GB | 43.25 GB |

Package e2e, Turbo at 1024² (`zimage-cli --pkg-e2e turbo`, MLX peak). Warm run time is 33.6 s on both
tiers, against 42.9 s (int4) and 36.4 s (bf16) for v0.5.0:

| Tier | v0.5.0 | v0.5.1 |
|---|---|---|
| int4 | 25,673 MiB | 23,060 MiB |
| bf16 | 33,917 MiB | 31,304 MiB |

### Output-size cap: area ≤ 1536² (v0.5.2, AB-T-0204)

`run()` throws `ZImagePackageError.sizeOutOfEnvelope` above `ZImageT2IPackage.maxOutputPixels`
(1536×1536, by area, so a non-square request of the same area is admitted) and below 16 px a side.
Before v0.5.2 any size ran, and the 1024²-measured footprint under-declared every larger request: the
decode alone is 27.7 GB at 1536² and 47.1 GB at 2048².

The rows are now declared at the cap and re-measured (`zimage-cli --pkg-e2e … --width 1536`, MLX
active/peak):

| Tier | Resident (after load) | Activation 1024² | Activation 1536² | Declared |
|---|---|---|---|---|
| bf16 | 20.49 GB | 12.34 GB | 27.68 GB | 20.5 + 28.0 GB |
| int8 | 14.85 GB | 12.34 GB | 27.68 GB | 15.0 + 28.0 GB |
| int4 | 11.84 GB | 12.34 GB | 27.68 GB | 11.9 + 28.0 GB |

- **Base (CFG) and Turbo measure the same** on every tier. The fp32 AE decode sets the activation,
  and it does not depend on the quant.
- **The int4 resident was under-declared at 6 GB.** That figure assumed an int4 text encoder, which
  was never shipped: the encoder is bf16 on every tier.
- **A 1024² request now over-reserves about 15 GB.** That is the price of one quant-keyed row
  covering the whole size range.

Gate: `ZIMAGE_PARITY=1 ZIMAGE_SNAPSHOT=… swift test -c release -Xswiftc -enable-testing --filter P3cVAEDecodeMemoryTests`.

## GPU numerics: the AE's 3×3 convs (2026-09-24)

mlx's Metal `conv2d` takes a Winograd F(6×6,3×3) path when the conv is 3×3, stride 1, dilation 1,
groups 1, C % 32 == 0, O % 32 == 0, C + O ≥ 256 and N·H·W ≥ 4096. On M5 that path loses precision:
about 6.4e-3 relL2 per conv in fp32, because its inner GEMM runs TF32, and about 5.8e-2 in bf16.

In the FLUX.1 AE, almost every 3×3 conv qualifies at ≥512²: at 1024² that is 31 decoder convs and 21
encoder convs. The old P3 gate pinned the CPU device, so the GPU lane had never been gated. Every
stride-1 3×3 conv is now a `WinogradFreeConv2d` with a route (`ZImageVAEConvRoute`): `.conv3d`
(exact, implicit GEMM), `.winograd` (mlx's raw path), or `.fp32Winograd` (bf16 upcast). Shapes
outside the window always take plain conv2d. **Defaults: encoder `.conv3d`, decoder `.winograd`.**

Measurements: 1024² DIV2K photo, each path against the CPU-lane fp32 result, M5 Max, mlx-swift 0.31.6.

| | Raw conv2d (Winograd) | conv3d route |
|---|---|---|
| Encode (img2img clean latent), GPU fp32 | **2.2e-2** · max 2.2 | 3.7e-4 · max 0.13 |
| Decode, GPU fp32 | 1.3e-3 · 70.0 dB · max 1.35e-2 | **2.0e-5 · 106.5 dB** |
| Decode, GPU bf16 | 1.2e-2 · 50.8 dB · max 0.124 | 3.8e-3 · 60.8 dB · max 0.028 |
| Decode time, fp32 / bf16 | 580 ms / 340 ms | **+463 ms / +622 ms** |
| Encode time, fp32 / bf16 | 319 ms / 184 ms | +173 ms / +321 ms |

Times are isolated GPU runs at 1024², median of 3 interleaved rounds.

- **The route is not cheap here.** Implicit-GEMM convs are 1.3–4× slower than Winograd at 256- and
  512-channel shapes.
- **The fp32 decode loss is below 8-bit visibility**: at most 2 levels on a [0, 255] output, while
  8-bit quantization alone is about 59 dB on this metric. The route would remove it at +80% decode
  time, so the decoder keeps mlx's path by default. Parity lanes opt in with
  `vae.decoderConvRoute = .conv3d`.
- **The encoder loss is material**: 2.2e-2 in the latent that seeds img2img. The encoder routes by
  default (`vae.encoderConvRoute`).
- `ZIMAGE_VAE_CONV_ROUTE=winograd|conv3d|fp32Winograd` overrides both defaults.
- With `MLX_ENABLE_TF32=0`, raw Winograd is exact too: decode is 1.0e-5 on both paths. That is the
  cheaper way to run a GPU parity lane.
- At 512² the encoder route is 6.5e-5 from the CPU lane (1.6e-5 with TF32 off), while raw
  Winograd is 1.7e-2. Most of the ~3.5e-4 left at 1024² is error in the CPU reference itself: its
  fp32 GroupNorm drifts with group size, to 8e-5 per full-resolution norm at 1024² against float64,
  where the GPU's stays at ~1e-7.

License: port code MIT; model weights Apache-2.0 (Tongyi-MAI).
