# Changes for NVAI-open / Änderungen für NVAI-open

Copy of [xocialize/z-image-swift](https://github.com/xocialize/z-image-swift) at commit eadca87 (2026-10-11), MIT
License (see `LICENSE`). Model: Tongyi-MAI Z-Image Turbo, Apache-2.0. Only `README.md`, `LICENSE` and
`Sources/ZImage` (the engine-agnostic core) were taken over; the `MLXZImage` wrapper (needs mlx-engine-swift),
the tests and `PORTING-SPEC.md` are left out.

Changed:
- `Package.swift`: only the `ZImage` library, macOS 14 instead of 26 (the app needs 15), no mlx-swift-lm, mlx-exact-conv-swift or
  mlx-profiling.
- `Adapted/Qwen3Encoder.swift`: RoPE from MLXNN and attention from MLXFast instead of mlx-swift-lm (one forward,
  no KV cache, no rope scaling in Qwen3-4B).
- `WinogradFreeConv2d.swift`: the routing of mlx-exact-conv-swift inlined (exact route = conv3d with kT = 1, as
  the file describes; Winograd = plain conv2d).
- `Pipeline.swift`: `precomputedPromptEmbeds` and an optional text encoder, so a small Mac can unload the text
  encoder before the DiT loads.
- `Weights.swift`: loaders for the pre-quantized `mflux-community/z-image-turbo-mflux-q4` (5.9 GB): mflux key
  names, quantization read from the checkpoint, built-in configs for Qwen3-4B and the FLUX.1 AE.
  `loadMFluxTransformer(precise:)` takes the layers that `keepHiPrecision` keeps at bf16 from a separate file
  (upstream names, from `mlx-community/Z-Image-Turbo-bf16`, 0.28 GB) instead of mflux's 4-bit ones: with those
  quantized, the image came out orange, blurred and with a 16-px patch grid.
- `TiledDecode.swift` (new): `AutoencoderKL.decodeTiled`, the fp32 decode in overlapping latent tiles with linear
  blending, so 1024² fits an 8 GB Mac (untiled about 12.3 GB, see the README).

Kopie von z-image-swift (MIT), nur der Kern `Sources/ZImage`. Geändert: ohne mlx-swift-lm, mlx-exact-conv-swift
und mlx-profiling (RoPE und Aufmerksamkeit aus MLX, exakte Faltung über conv3d), macOS 14 statt 26, Text-Merkmale vorab
übergeben (Text-Encoder entladen, bevor der DiT lädt), Lader für die vorquantisierten mflux-Gewichte (5,9 GB),
die empfindlichen Schichten dabei in bf16 aus einer eigenen Datei (0,28 GB), Dekodieren in Kacheln für 8-GB-Macs.
