# Changes for NVAI-open / Änderungen für NVAI-open

Copy of [VincentGourbin/flux-2-swift-mlx](https://github.com/VincentGourbin/flux-2-swift-mlx) 3.1.0
(commit ec4be31), MIT License (see `LICENSE`). Only `Package.swift`, `LICENSE`, `README.md`,
`Sources` and `Tests` were taken over; `docs` and `examples` are left out.

Changed: `Sources/Flux2Core/Pipeline/Flux2Pipeline.swift` calls `try Task.checkCancellation()` after
every denoising step, so NVAI-open can cancel a running image within one step instead of only after
the whole image.

Added (0.4.7): `Qwen35VLM.firstTokenLogProbs` returns the log-probabilities of the first answer token for given
candidates ("yes"/"no") without generating, so NVAI-open can decide "Automatic" restoring with a calibrated threshold.

Added (0.4.8): `KleinTextEncoder.upsamplePrompt(_:systemMessage:)` expands a prompt with a caller-defined system
message (same generation parameters as the image upsampling), so NVAI-open can expand prompts for video.

Changed (0.5.5): `Flux2WeightLoader.mergeLoRAWeights` merges only LoRA pairs whose shapes fit the layer and counts
the rest (`lastMergeCount`, `lastMergeSkipped`); `LoRALoader` skips pairs that are not two matrices. NVAI-open now
accepts LoRA files from the user's computer, and a LoRA for another model size (FLUX.2 Klein 9B on 4B) used to end the
whole app on a failed broadcast.

Kopie von flux-2-swift-mlx 3.1.0 (MIT). Geändert: Nach jedem Denoising-Schritt prüft
`Flux2Pipeline.swift` auf Abbruch, damit NVAI-open ein laufendes Bild innerhalb eines Schritts
abbrechen kann statt erst nach dem ganzen Bild.
Ergänzt (0.4.7): `Qwen35VLM.firstTokenLogProbs` liefert die Log-Wahrscheinlichkeiten des ersten Antworttokens für
vorgegebene Kandidaten („yes“/„no“), ohne zu generieren – für „Automatisch“ beim Restaurieren mit einer gemessenen
Schwelle.
Ergänzt (0.4.8): `KleinTextEncoder.upsamplePrompt(_:systemMessage:)` baut einen Prompt mit eigenem Systemprompt aus
(gleiche Einstellungen wie beim Bild) – für „Prompt ausbauen“ im Video-Reiter.
Geändert (0.5.5): `Flux2WeightLoader.mergeLoRAWeights` verrechnet nur LoRA-Paare, deren Form zur Schicht passt, und
zählt die übrigen (`lastMergeCount`, `lastMergeSkipped`); `LoRALoader` überspringt Paare, die keine zwei Matrizen sind.
NVAI-open nimmt seither LoRA-Dateien vom Rechner an, und eine LoRA für eine andere Modellgröße (FLUX.2 Klein 9B auf
4B) beendete vorher die ganze App an einem gescheiterten Broadcast.
