# Changes for NVAI-open / Änderungen für NVAI-open

Copy of [xocialize/seedvr2-mlx-swift](https://github.com/xocialize/seedvr2-mlx-swift) at commit 1dfa161
(2026-06-15, the repository is archived). Port code: MIT, as stated in its README ("Port code: MIT"; the
repository has no separate LICENSE file, so `LICENSE` here is the standard MIT text with the copyright line the
same author uses in its other ports, e.g. z-image-swift: "Copyright (c) 2026 Xocialize"). SeedVR2 model and weights: Apache-2.0 (ByteDance Seed). Only
`README.md` and `Sources/SeedVR2MLX` were taken over; the CLI smoke harness (`Sources/RunUpscale`), the
parity tests and `docs` are left out.

Changed: `Package.swift` keeps only the library target (no swift-argument-parser). The sources are
unchanged. NVAI-open adds the host steps the README leaves to the host (pre-upscale, tiling with blended
overlaps, color correction per tile) in `mac/NVAIMac/Sources/Engine/SeedVR2Engine.swift`.

Kopie von seedvr2-mlx-swift (Commit 1dfa161, Repository archiviert). Port-Code laut README MIT, Modell und
Gewichte Apache-2.0. Übernommen: README und Sources/SeedVR2MLX; Package.swift nur mit der Bibliothek. Die
Schritte, die der Port dem Aufrufer überlässt (Vorvergrößern, Kacheln mit weichen Übergängen,
Farbkorrektur je Kachel), stehen in `Sources/Engine/SeedVR2Engine.swift` der App.
