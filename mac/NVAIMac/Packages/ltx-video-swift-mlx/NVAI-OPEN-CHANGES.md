# Changes for NVAI-open

Local copy of [VincentGourbin/ltx-video-swift-mlx](https://github.com/VincentGourbin/ltx-video-swift-mlx) at tag
v0.4.2 (MIT, see LICENSE), used by NVAI-open for Mac for LTX-2.3 and LTX-2.5 with sound on Macs with 32 GB or more.

- Only the `LTXVideo` library: the CLI (`LTXVideoCLI`), tests, docs, scripts and the author's agent instruction files
  are left out.
- `mlx-swift` pinned exactly to 0.31.6 (as in NVAI-open's FLUX.2 copy) and `mlx-swift-lm` to 3.31.4..<3.32.0 instead
  of `branch: "main"`: v0.4.2 was built against mlx-swift 0.31.6 (its Package.resolved), while today's mlx-swift-lm
  main requires mlx-swift 0.33 and would conflict with the rest of the app.
- `Utils/VideoExporter.swift`: the status of `CMAudioFormatDescriptionCreate` is compared with `0` (the same value as
  the named constant).
