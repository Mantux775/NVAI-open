# Changes for NVAI-open / Änderungen für NVAI-open

Copy of [VincentGourbin/flux-2-swift-mlx](https://github.com/VincentGourbin/flux-2-swift-mlx) 3.1.0
(commit ec4be31), MIT License (see `LICENSE`). Only `Package.swift`, `LICENSE`, `README.md`,
`Sources` and `Tests` were taken over; `docs` and `examples` are left out.

Changed: `Sources/Flux2Core/Pipeline/Flux2Pipeline.swift` calls `try Task.checkCancellation()` after
every denoising step, so NVAI-open can cancel a running image within one step instead of only after
the whole image.

Kopie von flux-2-swift-mlx 3.1.0 (MIT). Geändert: Nach jedem Denoising-Schritt prüft
`Flux2Pipeline.swift` auf Abbruch, damit NVAI-open ein laufendes Bild innerhalb eines Schritts
abbrechen kann statt erst nach dem ganzen Bild.
