# Changes for NVAI-open / Änderungen für NVAI-open

Taken from [soniqo/speech-swift](https://github.com/soniqo/speech-swift) at commit cbad3be (2026-10-25),
Apache License 2.0 (see `LICENSE`). Copied: the module `Sources/StableAudio3MusicGen` (Stable Audio 3 Medium:
T5Gemma text encoder, DiT, SAME-L decoder, ping-pong flow sampler) plus the helpers it uses from other
modules of that package: `SentencePieceModel.swift` and `DownloadOptions.swift` (AudioCommon) and
`MLXCacheLimit.swift`, `PreQuantizedLinear.swift`, `ThrowawayRandomState.swift` (MLXCommon). Model weights: `aufklarer/Stable-Audio-3-DiT-Medium-MLX-8bit`, Stability AI
Community License (free below US$1M annual revenue).

Changed:
- All files live in one target `StableAudio3`; the `import AudioCommon` / `import MLXCommon` lines are gone.
- `StableAudio3Downloader.ensureDownloaded` no longer downloads: NVAI-open fetches the bundle into its own model
  folder and passes it as `localBundleOverride`. The SAME encoder is not required (only audio-to-audio uses it).
- `StableAudio3Error.missingBundle` added.
- `DiTMedium`: the zero local conditioning takes the latent length of the call (`x.dim(2)`) instead of the
  `tLat` fixed at load time; before, any duration other than the load hint (30 s) failed with a broadcast error.

Übernommen aus speech-swift (Apache-2.0): das Modul für Stable Audio 3 Medium und fünf Hilfsdateien. Geändert:
ein gemeinsames Target, kein eigener Download (die App lädt die Gewichte in ihren Modellordner), der SAME-Encoder
wird nicht verlangt (braucht nur Audio zu Audio), und der DiT nimmt die Länge des Aufrufs statt der beim Laden
festgelegten (sonst scheiterte jede andere Dauer als 30 s).
