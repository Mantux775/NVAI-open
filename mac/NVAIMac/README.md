# NVAI-open for Mac

A native macOS app (SwiftUI, Apple Silicon, macOS 15 or later) that generates images, video, music and sounds locally,
restores old photos and has the Studio for whole videos. It serves the same REST API as NVAI-open for Windows (contract
`server/openapi.json`), so the PhotoCraft add-on and Claude Code talk to it unchanged at `http://127.0.0.1:8100`.

License: MIT. Third-party components: `Resources/Third-Party-Notices.txt` (also in the app under NVAI-open > Licenses).
Models are not part of the app; the model list shows each model's license.

## Languages

Settings > Language offers Automatic (system language; anything but German means English), English and German. All
visible texts go through `t("Deutsch", "English")` (`Sources/Core/Lang.swift`). The API answers in the language of the
request's `Accept-Language` (`de` → German, otherwise English).

## Engines

| What | Engine | Models | Memory |
|---|---|---|---|
| Images | MLX ([flux-2-swift-mlx](https://github.com/VincentGourbin/flux-2-swift-mlx) 3.1.0, local copy) | FLUX.2 Klein 4B, 4 or 8 bit: generate, image-to-image, fill, extend, up to 3 reference images | 4 bit from 8 GB, 8 bit from 24 GB |
| | MLX (`z-image-swift`, local copy) | Z-Image Turbo, text to image, 8 steps | 1 MP from 8 GB |
| | Core ML ([ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion)) | Stable Diffusion pipelines, also from the model search; fixed size | from 8 GB |
| Video | MLX (own port `ltxv-swift`) | LTX-Video 2B 0.9.8 distilled from text or a start image; LTX-Video 13B | 2B from 8 GB, 13B from 16 GB |
| | MLX (`ltx-video-swift-mlx`, local copy) | LTX-2.3 and LTX-2.5 with sound | from 32 / 64 GB, macOS 26.3 |
| Sound | MLX (`stable-audio-3-swift`, local copy) | Stable Audio 3 Medium: music and sounds | from 8 GB |
| Speech | MLX (`qwen3-tts-swift`, local copy of the Qwen3-TTS part of mlx-audio-swift) | Qwen3-TTS: VoiceDesign 1.7B 4-bit (a voice from a description), Base 0.6B 8-bit (a voice from a recording), 10 languages | from 8 GB |
| Photos | MLX (`seedvr2-mlx-swift`, local copy) and FLUX.2 Klein | restore, colorize, sharpen with SeedVR2 3B; "Automatic" asks Qwen3.5 4B | from 8 GB |

The local copies under `Packages/` say in their `NVAI-OPEN-CHANGES.md` what was changed (for example a cancellation
check after every FLUX.2 step).

Measured on a Mac mini M1 with 8 GB: FLUX.2 Klein 4-bit 512 × 512 in 40.5 s (peak 4.4 GB, bit-identical to the
package CLI), 1184 × 880 in 109 s; LTX-Video 2B 768 × 512 × 97 frames in 174 s (peak 6.2 GB); 30 s of music in about
13 s; a described voice in 0.9 times real time (peak 3.9 GB). The 13B and LTX-2 models are recommended by memory
from their authors' figures, not measured.

## Studio

Same project format, commands and REST routes as on Windows (`Sources/Studio/`, `Sources/UI/Studio/`,
`Sources/Server/StudioRoutes.swift`): two timelines, generate with progress and cancel (`POST …/cancel`, feature
`studio_cancel`), conform, cut, export with AVFoundation at −14 LUFS. A chained scene starts from the last frame; the
latent chain (last second carried over) stays on Windows. Voice scenes speak with Qwen3-TTS like on Windows
(`params.voice`, `voice_from`, `voice_asset_id`, `voice_text`, `language`); a voice scene takes the length of its take.

## Other features

- **Outpainting** (`outpaint=[left, top, right, bottom]`): the Mac fills the border with a mask and puts the original
  back (`Sources/Core/OutpaintMask.swift`); the reference way used on Windows failed with FLUX.2 Klein 4B.
- **Expand prompt** (`POST /api/prompt/expand`): the Qwen3-4B text encoder of FLUX.2 Klein writes the description, no
  extra download; 22–25 s on the M1.
- **Cancelling:** downloads stop at once without a partial file; a FLUX.2 image stops within one step, Core ML at the
  next step.
- **Content labels:** every model shows whether it is censored (`Sources/Core/ContentRating.swift`).
- **Problem report:** Settings > "Report a problem" (`Sources/Core/ProblemReport.swift`), anonymized like on Windows.

## Build (this folder is the source, the build runs on a Mac)

```sh
MAC_HOST=my-mac scripts/sync.sh                     # copy the source to ~/NVAIMac, run XcodeGen
ssh my-mac 'zsh ~/NVAIMac/scripts/build.sh'          # xcodebuild, signed ad hoc
```

- Build with **xcodebuild**, not `swift build`: only Xcode compiles the MLX Metal shaders, which needs the Metal
  Toolchain once (`xcodebuild -downloadComponent MetalToolchain`).
- `~/NVAIMac` on the Mac is only a mirror; `Sources` is replaced on every sync.
- Package versions are pinned in `Package.resolved`. After a package update, regenerate the notices:
  `python3 scripts/make-notices.py ~/NVAIMac/SourcePackages/checkouts Package.resolved Resources/Third-Party-Notices.txt`

## Run for tests

```sh
open -n ~/NVAIMac/dd/Build/Products/Release/NVAI-open.app --args -serverPort 8110 -modelsDirectory /path/to/models
curl -s http://127.0.0.1:8110/api/version
```

- Settings can be overridden at launch (`-serverPort`, `-modelsDirectory`, `-activeModelID`, `-language en|de|auto`).
- Data: `~/Library/Application Support/NV-AI`; log: `~/Library/Logs/NV-AI/nvai.log`.
- The server starts with the app, independently of the window; if the port is busy, it retries every 2 s.
- Checks without a screen: `NVAI-open --snapshot <png> [--tab studio|generate|history|models|settings] [--report <md>]
  --quit` renders the app's own window without screen recording permission.

## Release

```sh
ADDON_DIR=/path/to/photocraft-addon zsh ~/NVAIMac/scripts/release.sh
```

The result is `~/NVAIMac/release/NVAI-open-<version>.dmg` with NVAI-open.app, the PhotoCraft add-on app (if
`ADDON_DIR` points to its `build-app.sh`), `Getting Started.txt`, `Erste Schritte.txt` and `Third-Party Notices.txt`.
With a "Developer ID Application" certificate the apps and the DMG are signed, notarized and stapled; without one the
DMG is only signed ad hoc, for internal tests. Over SSH with a locked keychain, pipe the password in and pass
`--unlock-from-stdin`.

## Limits

- Qwen-Image and FLUX 3 do not run on the Mac; there are no native, freely licensed ports yet.
- Core ML models have a fixed size; other sizes are stretched.
