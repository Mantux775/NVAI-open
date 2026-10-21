# NV-AI for Mac

A native macOS app (SwiftUI, Apple Silicon, macOS 15 or later) that generates images locally and
serves the same REST API as NV-AI for Windows (contract `server/openapi.json`, `api` 1). The
PhotoCraft add-on talks to it unchanged at `http://127.0.0.1:8100`.

License: MIT. Third-party components: `Resources/Third-Party-Notices.txt` (also in the app under
NV-AI > Licenses). Models are not part of the app; the model list shows each model's license.

## Languages

Settings > Language offers Automatic (system language; anything other than German means
English), English and German. The menu bar follows the choice after a restart: the app sets
`AppleLanguages` for itself, and `Info.plist` lists `CFBundleLocalizations` (en, de). All visible texts go
through `t("Deutsch", "English")` (`Sources/Core/Lang.swift`); there is no string catalog.

The API answers in the language the client sends in `Accept-Language` (`de` → German, otherwise
English; no header → English): model descriptions, prompt hints, size labels and error
messages. Jobs keep the language of the request that created them.

## Engines

| Engine | Models | Capabilities | Memory |
|---|---|---|---|
| MLX ([flux-2-swift-mlx](https://github.com/VincentGourbin/flux-2-swift-mlx) 3.1.0) | FLUX.2 Klein 4B, 4-bit or 8-bit (Apache-2.0) | generate, image-to-image (`denoise`), masked fill, up to 3 reference images | 4-bit from 8 GB, 8-bit from 24 GB |
| Core ML ([ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion)) | Stable Diffusion 1.5/2.1/SDXL as compiled Core ML pipelines, plus results from the Hugging Face search | generate, image-to-image (with VAE encoder), negative prompt; fixed size | from 8 GB |

Measured on an M1 with 8 GB (FLUX.2 Klein 4B, 4-bit, 4 steps):

- **Direct:** 512 × 512 takes 40.5 s with a 4.4 GB peak; the output is bit-identical to the package CLI.
- **PhotoCraft-style jobs at 1184 × 880:** generate 109 s (7.9 GB peak), refine (`denoise` 0.5) 65 s, fill 109 s. The area outside the mask stays unchanged (mean difference 0.12/255).

On 8 GB, 1 megapixel is the practical limit; 16 GB or more is comfortable.

## Expand prompt

"✨ Expand prompt" (Generate page) and `POST /api/prompt/expand` (feature `expand_prompt`, same
shape as on Windows) turn a few words into a full image description. The Qwen3-4B text encoder of
FLUX.2 Klein writes it (`KleinTextEncoder.upsamplePrompt`, Black Forest Labs' system prompt, no
thinking mode); no extra download. It runs as a job in the queue, which is deleted afterwards. On
Macs with up to 16 GB the image model is unloaded first. Measured on an M1 with 8 GB: 22–25 s,
35 s the first time after starting; a 512 × 512 image right afterwards took 41.9 s.

## Build (this folder is the source, the build runs on a Mac)

```sh
MAC_HOST=my-mac scripts/sync.sh                     # copy the source to ~/NVAIMac, run XcodeGen
ssh my-mac 'zsh ~/NVAIMac/scripts/build.sh'          # xcodebuild, signed ad hoc
```

- Build with **xcodebuild**, not `swift build`: only Xcode compiles the MLX Metal shaders, which needs the Metal Toolchain once (`xcodebuild -downloadComponent MetalToolchain`).
- `~/NVAIMac` on the Mac is only a mirror. `Sources` is replaced on every sync.
- Package versions are pinned in `Package.resolved`; `build.sh` hands the file back.
- After a package update, regenerate the notices from the real license files:
  `python3 scripts/make-notices.py ~/NVAIMac/SourcePackages/checkouts Package.resolved Resources/Third-Party-Notices.txt`

## Run for tests

```sh
open -n ~/NVAIMac/dd/Build/Products/Release/NV-AI.app --args -serverPort 8110 -modelsDirectory /path/to/models
curl -s http://127.0.0.1:8110/api/version
```

- **Settings:** each one can be overridden at launch this way (`-serverPort`, `-modelsDirectory`, `-activeModelID`, `-language en|de|auto`).
- **Data:** `~/Library/Application Support/NV-AI` (`assets/` with `index.json`).
- **Models:** in the model folder, FLUX.2 under `<organization>/<repo>`, Core ML under `coreml/<id>`. The folder must be named `models`.
- **Server start:** The server starts in the app delegate at launch, before anything else and independent of the window. Measured with `open -g -j` (hidden, in the background): it listens after 1 s. If the port is busy, it retries every 2 s.
- **Log:** `~/Library/Logs/NV-AI/nvai.log` (rotated at 5 MB) records start, server state, jobs and errors.
- **Checks without a screen:** `NV-AI --snapshot <png> [--tab generate|history|models|search|settings] [--report <md>] --quit` renders the app's own window with cacheDisplay, which needs no screen recording permission. `--report` writes the test report.

## Release

```sh
NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer-uuid> \
ADDON_DIR=/path/to/photocraft-addon zsh ~/NVAIMac/scripts/release.sh
```

The result is `~/NVAIMac/release/NV-AI-<version>.dmg` containing:
- NV-AI.app
- the PhotoCraft add-on app, if `ADDON_DIR` points to its `build-app.sh`
- `Getting Started.txt`, `Erste Schritte.txt` and `Third-Party Notices.txt`

**Signing:**
- **With a "Developer ID Application" certificate:** the apps are signed, notarized and stapled, then the DMG the same way.
- **Without one:** the DMG is only signed ad hoc, for internal tests.
- **Locked keychain over SSH:** pipe the password in and pass `--unlock-from-stdin`.

## Limits

- **Cancelling:** A running FLUX.2 image cannot be cancelled because the package never checks for cancellation. The job ends after the current image. Core ML stops at the next step.
- **Unsupported models:** Qwen-Image and FLUX 3 do not run on the Mac; there are no native, freely licensed ports yet.
- **Fixed sizes:** Core ML models have a fixed size; other sizes are stretched to the requested size.
