# Installing NV-AI

*Deutsch: [de/INSTALL.md](de/INSTALL.md)*

NV-AI generates media locally on your own hardware:

- **Windows:** images, audio, video and 3D meshes on an NVIDIA graphics card, with a web UI
  and an MCP server for Claude Code.
- **macOS:** a native app for Apple Silicon that generates images.

Both offer the same REST API on `http://127.0.0.1:8100`.

- [Windows: install with the setup](#windows-install-with-the-setup)
- [macOS: install from the DMG](#macos-install-from-the-dmg)
- [Building from source](#building-from-source)
- [Optional: PhotoCraft add-on](#optional-photocraft-add-on)

---

## Windows: install with the setup

`NV-AI-Setup-<version>.exe` needs neither Python nor git. It brings its own copy of uv and uses
it to install Python, ComfyUI and PyTorch in the tested package versions. It installs for the
current user only and needs no administrator rights.

### Requirements

| | |
|---|---|
| **Windows** | Windows 10 (version 2004 or later) or Windows 11, 64-bit |
| **Graphics card** | NVIDIA; 8 GB of VRAM is workable, 12–16 GB is comfortable |
| **Driver** | 580.88 or newer (branch R580, needed by PyTorch with CUDA 13): https://www.nvidia.com/drivers |
| **Internet** | about 3 GB during setup (mostly PyTorch), plus 5–30 GB per model |
| **Disk** | about 10 GB for the program, plus room for the models |

The setup checks the graphics card and driver and warns if no NVIDIA card is found or the
driver is too old. Without an NVIDIA card NV-AI can be installed, but it cannot generate
anything.

### Experimental (0.5 beta): AMD Radeon and several graphics cards

- **AMD Radeon:** the setup detects a Radeon (and no NVIDIA card) and installs PyTorch with
  ROCm 7.2.1 from AMD (`locks\comfyui-amd-base.lock` plus `locks\comfyui-rocm.lock`, both with
  hashes). Needs AMD driver 26.2.2 or newer. 3D is skipped on AMD. "Repair NV-AI" runs the same
  detection again; `install-runtime.ps1 -Gpu amd|nvidia` forces one side.
- **Several NVIDIA cards:** under "Models" → "Graphics cards", choose a card for image models,
  language models and 3D. If the language models get their own card, NV-AI starts a second
  ComfyUI for them (port 8189, logs in `comfyui-text.log`). The choice is stored in
  `gpus.json` in the data folder; deleting it puts everything back on card 0.
- For testing without the hardware: `NVAI_SIMULATE_GPUS=2` reports the one card twice, and
  `NVAI_TEXT_BACKEND=separate` forces the second ComfyUI on a single card.

### Windows SmartScreen

The setup is not code-signed, so Windows may show **"Windows protected your PC"**. Click
**More info**, then **Run anyway**.

### Installing

1. Run `NV-AI-Setup-<version>.exe`.
2. Choose the program folder (default `%LOCALAPPDATA%\Programs\NV-AI`).
3. Choose the folders for data (images, settings, logs; default `%LOCALAPPDATA%\NV-AI`) and
   for models (default `%LOCALAPPDATA%\NV-AI\models`). Each model is 5 to 30 GB, so a folder
   on a large drive makes sense. Both folders must be outside the program folder: uninstalling
   removes the program folder, and your models and images should survive that.
4. Choose the installation type. **Full installation** adds the 3D component (TripoSG, which
   turns images into 3D meshes; the model itself, 7.4 GB, is downloaded later in NV-AI) and,
   if the setup includes it, the PhotoCraft add-on (see
   [Optional: PhotoCraft add-on](#optional-photocraft-add-on)). **NV-AI only** covers images,
   audio and video. **Custom** lets you pick the components.
5. After copying its files, the setup installs Python, ComfyUI and PyTorch (about 3 GB); with
   the 3D component it also sets up TripoSG's environment, which reuses the same PyTorch. A
   console window stays open while this happens and closes by itself at the end. This takes 5
   to 20 minutes.

If this last step fails, the setup shows the path of `install.log`. You can retry later with
**Repair NV-AI** in the Start menu.

### First steps

1. Open **NV-AI** from the Start menu. Your browser shows the web UI at
   `http://127.0.0.1:8100`.
2. Under **Models**, download an image model. NV-AI marks models that suit your graphics card
   as *recommended* (see [Models](#models)).
3. Under **Generate**, enter a prompt. The first job after a start takes an extra 30 to 60
   seconds because the model is being loaded.

**Quit NV-AI** in the Start menu shuts everything down and frees the graphics card. The Start
menu also has **Repair NV-AI**, **Getting Started** and, with the add-on, **NV-AI for
PhotoCraft**.

To use NV-AI from Claude Code, see [CLAUDE_CODE.md](CLAUDE_CODE.md).

### FLUX 3 Image Klein (Hugging Face access)

Black Forest Labs puts this model behind a license confirmation. You need a free account at
https://huggingface.co:

1. Accept the license at https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy.
2. Create a token with read access at https://huggingface.co/settings/tokens.
3. Enter the token in NV-AI under **Models**.

License: commercial use only below US$5 million annual revenue, and every image must be
reviewed before it is published. Details in [MODELS.md](MODELS.md).

### Models

**No models are included** — together they weigh more than a hundred gigabytes. Download them
in the web UI under **Models**, where each model is described with its size, VRAM requirement
and license.

- NV-AI detects the graphics card and marks suitable models as *recommended*: on RTX 50 cards
  Qwen-Image-2512 and FLUX 3 Image Klein in NVFP4, on RTX 20/30/40 cards FLUX 3 Image Klein
  INT8 and Z-Image INT8.
- Models that don't fit into the card's video memory are marked explicitly (*tight for this
  GPU* or *too large for this GPU*). A model that doesn't fit still runs, but has to be
  reloaded at every step and is therefore many times slower.
- **Search Hugging Face** on the same page finds further models. NV-AI checks each file before
  downloading it; SDXL and SD 1.5 checkpoints can be downloaded.

**A good start depending on your card:**

| VRAM | Image | Video | 3D |
|---|---|---|---|
| 16 GB | `chroma1-hd-fp8` | `wan22-ti2v-5b` | `trellis2-4b` |
| 12 GB | `z-image` | `wan21-t2v-1.3b` | `triposg` |
| 8 GB | `z-image-int8` | `ltxv-2b-095` | `triposg` (tight) |

For 3D, the setup's full installation includes TripoSG. TRELLIS.2 (`trellis2-4b`, with PBR
textures) is only available when you install from source (see
[Optional: 3D workers](#optional-3d-workers)).

The two recommended image models, Qwen-Image-2512 and FLUX 3 Image Klein, are described in
detail in [MODELS.md](MODELS.md).

### Logs and repair

If something goes wrong, these files help. They are in the data folder (default
`%LOCALAPPDATA%\NV-AI`):

| File | Contents |
|---|---|
| `install.log` | setup |
| `nvai-server.log` | server |
| `comfyui.log` | generation (ComfyUI) |

**Repair NV-AI** in the Start menu runs the installation of Python, ComfyUI and PyTorch again.

The setup stores its settings in the registry under `HKCU\Software\NV-AI`: program, data and
model folders and the port (8100). If another program uses port 8100, enter a different `Port`
there.

### Updating and uninstalling

- **Update:** run the newer setup. It first stops an NV-AI that is still running from the old
  installation and suggests your previous data and model folders.
- **Uninstall:** via **Settings → Apps → NV-AI**. The uninstaller removes the program folder
  and then asks whether to delete the data and models as well. Answer **No** to keep them for a
  later installation.

---

## macOS: install from the DMG

NV-AI for Mac is a native app (SwiftUI) that generates images locally. It offers the same REST
API as NV-AI on Windows, so the PhotoCraft add-on works with it unchanged.

### Requirements

| | |
|---|---|
| **Mac** | Apple Silicon, macOS 15 or later |
| **Memory** | FLUX.2 Klein 4B in 4 bit from 8 GB (comfortable from 16 GB), in 8 bit from 24 GB |
| **Internet** | for the first model download: FLUX.2 Klein 4B, about 10 GB, once |
| **Disk** | about 1 GB for the app, plus about 10 GB for FLUX.2 Klein |

### Installing

The DMG is signed and notarized by Apple.

1. Open `NV-AI-<version>.dmg` and drag **NV-AI** into your Applications folder. If you use
   PhotoCraft, drag the add-on app **NV-AI für PhotoCraft** there as well.
2. Open NV-AI. Under **Models**, download FLUX.2 Klein (about 9 to 11 GB, once). With 24 GB of
   memory or more, choose the 8-bit version; below that, the 4-bit version.
3. Under **Generate**, enter a prompt. The first image takes longer because the model is being
   loaded.

NV-AI for Mac starts its server as soon as the app launches, independently of the window. It
listens on `127.0.0.1:8100` only; the PhotoCraft add-on and your own scripts reach NV-AI at
`http://127.0.0.1:8100`.

### What runs on the Mac

| Engine | Models | Can do | Memory |
|---|---|---|---|
| MLX (`flux-2-swift-mlx` 3.1.0, MIT) | FLUX.2 Klein 4B, 4 bit or 8 bit (Apache-2.0) | generate, image-to-image (`denoise`), fill with a mask, up to 3 reference images | 4 bit from 8 GB, 8 bit from 24 GB |
| Core ML (`ml-stable-diffusion`) | Stable Diffusion 1.5/2.1/SDXL as ready-made Core ML pipelines, plus hits from the model search | generate, image-to-image (with VAE encoder), negative prompt; fixed size | from 8 GB |

Measured on a Mac mini (M1, 8 GB), FLUX.2 Klein 4B, 4 bit, 4 steps:

- 512 × 512: 40.5 s, peak memory 4.4 GB. The result is bit-identical to the package's CLI.
- Jobs from the PhotoCraft add-on at 1184 × 880: generate 109 s (peak 7.9 GB), rework
  (`denoise` 0.5) 65 s.

On 8 GB that is the limit. From 16 GB it runs comfortably.

Limits:

- Qwen-Image and FLUX 3 do not run on the Mac; there are no native, free ports for them yet.
- A running FLUX.2 image cannot be cancelled: the package never checks for cancellation, so
  cancelling takes effect after the current image. Core ML stops at the next step.
- Core ML models have a fixed size. Other sizes are stretched to the requested size.

### Files and feedback

- Data: `~/Library/Application Support/NV-AI` (`assets/` with `index.json`).
- Log: `~/Library/Logs/NV-AI/nvai.log` (start, server status, jobs and errors).
- To report a problem, save the test report under **Settings → Save test report…** and attach
  it. It contains the Mac model, memory, and the duration and memory use per image — no
  prompts.

---

## Building from source

### Windows development setup

| | |
|---|---|
| **NVIDIA graphics card** | 8 GB of VRAM is workable, 12–16 GB is comfortable. Current driver (580.88 or newer) |
| **Windows 10/11** | the scripts are PowerShell |
| **git** | https://git-scm.com/download/win |
| **uv** | `winget install astral-sh.uv` — creates the Python environments |
| **Node.js** | `npm` builds the web UI; the built `frontend/dist` is not in the repository |
| **Disk** | 30 GB for the installation, plus **5–30 GB per model** |

Python does not need to be installed; uv fetches a suitable version itself.

```powershell
git clone https://github.com/Mantux775/NVAI-open.git
cd NVAI-open
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

The script fetches ComfyUI at the tested version 0.42.1, creates two separate Python
environments (orchestrator, and GPU backend with PyTorch for CUDA 13), builds the web UI if npm
is available, detects the graphics card and finally lists the models that fit this card. Expect
10–20 minutes, most of it PyTorch.

#### Starting and stopping

```powershell
scripts\start.ps1     # then open http://127.0.0.1:8100
scripts\stop.ps1      # stops NV-AI and ComfyUI specifically
```

ComfyUI starts automatically with the first job (about 30 s, once). If port 8100 is already in
use, `start.ps1` tells you which process holds it instead of starting a second server.

#### Access from other devices

```powershell
scripts\start.ps1 -Lan
```

The server then also listens on the network. Other devices (for example the PhotoCraft add-on
on another computer) must send a token in the `X-NVAI-Token` header; this computer itself
doesn't need one. The token comes from `$env:NVAI_TOKEN`, otherwise from `data\api_token`; if
neither exists, `-Lan` creates the file with 32 random bytes. On a home network the connection
is plain HTTP, token included, so from outside use a VPN such as Tailscale. On the first start,
Windows Firewall asks for permission — allow private networks.

#### Claude Code

```powershell
claude mcp add --scope user nvai -- "<repository folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

After that, `health`, `generate_image`, `generate_video`, `image_to_3d` and model management are
available there as tools. Details and prompt advice: [CLAUDE_CODE.md](CLAUDE_CODE.md).

#### Optional: 3D workers

Mesh generation runs in separate processes with their own dependencies:

```powershell
scripts\setup_triposg.ps1     # geometry, MIT license
scripts\setup_trellis2.ps1    # geometry + PBR textures, needs a C++ compiler
```

Both scripts expect the upstream repository to be cloned into `external\triposg` or
`external\trellis2` first. TRELLIS.2 compiles a CUDA extension and requires the **Visual Studio
2022 Build Tools** with the C++ tools. If you don't need 3D, skip both.

#### Repository layout

```
server/             orchestrator (FastAPI), MCP server, 3D workers (server/workers)
frontend/           web UI (React/Vite), built into frontend/dist/
scripts/            setup, start, stop
packaging/windows/  Windows setup (Inno Setup)
packaging/tools/    release helpers
mac/NVAIMac/        NV-AI for Mac (SwiftUI)
photocraft-addon/   PhotoCraft add-on
docs/               documentation
data/               created on first start: models, assets, database
external/           created during installation: ComfyUI
```

### Building the Windows setup

```powershell
cd frontend; npm install; npm run build; cd ..
packaging\windows\build-setup.ps1 [-Addon <folder>]
```

Requirements:

- **Inno Setup 6:** `winget install JRSoftware.InnoSetup --scope user`. The script looks for
  `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`.
- **uv** and **Python 3** on the `PATH`: `uv.exe` is copied into the setup, and Python runs the
  generator for the third-party notices (`packaging\tools\third_party_notices.py`).
- The built web UI (`frontend\dist`).

The script stages only what belongs in the setup under `packaging\windows\build\stage`: the
server code with the 3D workers (without venv), `pyproject.toml`, `openapi.json`, the built web
UI, ComfyUI at the tested tag `v0.42.1` and TripoSG at a pinned commit, `uv.exe` with its
license files, the locked package lists from `packaging\windows\locks`, the license and the
generated third-party notices. ComfyUI and TripoSG are exported with `git archive` from local
clones in `external\` if present (no models, no venv, no outputs), otherwise downloaded from
GitHub. Then the script runs Inno Setup. The result is
`packaging\windows\build\NV-AI-Setup-<version>.exe`; the version comes from
`server\nvai\__init__.py`.

- The PhotoCraft add-on becomes an optional component if a built add-on folder (with
  `requirements.lock`) is found: `-Addon <folder>`, otherwise `$env:NVAI_ADDON_DIR`, otherwise
  `photocraft-addon\dist\addon` (built with `photocraft-addon\tools\build_addon.py`). Without
  it, the setup is built without the PhotoCraft component.
- On the target PC, the setup installs Python 3.12.13 into the program folder and exactly the
  package versions listed in `locks\`, verified by sha256 hashes
  (`uv pip sync --require-hashes`): the same versions that were tested.
- The bundled `.ps1` scripts must be pure ASCII, because Windows PowerShell 5.1 reads scripts
  without a BOM as ANSI. The build script checks this.

### Building the Mac app

Requirements: a Mac with Apple Silicon, Xcode with the Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`, once) and XcodeGen.

- Build with **xcodebuild**, not `swift build`: only Xcode compiles MLX's Metal shaders.
- `project.yml` is the XcodeGen spec; the generated `.xcodeproj` is not in the repository.
- Package versions are pinned in `Package.resolved`.

The scripts in `mac/NVAIMac/scripts` expect the project in `~/NVAIMac` on the Mac:

| Script | What it does |
|---|---|
| `sync.sh` | For developing on Windows, run from Git Bash: copies `project.yml`, `Sources`, `Resources`, `scripts` and `Package.resolved` over SSH to `~/NVAIMac` on a Mac reachable as `macmini` and runs `xcodegen generate` there (XcodeGen expected at `~/tools/xcodegen/bin/xcodegen`). `~/NVAIMac` is only a mirror: `Sources` is replaced on every sync |
| `build.sh` | builds `~/NVAIMac/dd/Build/Products/Release/NV-AI.app` (Release, arm64, ad-hoc signed); log in `~/NVAIMac/build.log` |
| `release.sh` | builds the DMG (see below) |

Working directly on a Mac: copy `mac/NVAIMac` to `~/NVAIMac`, run `xcodegen generate` there and
copy `Package.resolved` to `NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. These
are the steps `sync.sh` runs on the Mac. Then:

```sh
zsh ~/NVAIMac/scripts/build.sh
```

Test run with settings overridden at launch (`-serverPort`, `-modelsDirectory`,
`-activeModelID`):

```sh
open -n ~/NVAIMac/dd/Build/Products/Release/NV-AI.app --args -serverPort 8110 -modelsDirectory <models folder>
curl -s http://127.0.0.1:8110/api/version
```

- If the port is in use, the server retries every 2 s.
- Checking without a display: `NV-AI --snapshot <png> [--tab generate|history|models|search|settings] [--report <md>] --quit`
  captures the app's own window and needs no screen recording permission; `--report` also
  writes the test report.

#### Release DMG

```sh
zsh ~/NVAIMac/scripts/release.sh
```

The result is `~/NVAIMac/release/NV-AI-<version>.dmg` with NV-AI.app, the PhotoCraft add-on app
and a getting-started text. The add-on is built with its own `build-app.sh` from the folder set
in `ADDON_SRC` at the top of the script; if it is missing there, the DMG is built without the
add-on.

- **With a "Developer ID Application" certificate** in the keychain, the apps are signed
  (hardened runtime, timestamp), notarized by Apple and stapled, then the same happens to the
  DMG. Notarization needs an App Store Connect API key for `notarytool`; see `notarize()` in
  the script.
- **Without a certificate**, the DMG is only ad-hoc signed and not notarized. Gatekeeper blocks
  it on other Macs, so it is only suitable for internal tests.
- **Keychain locked** in an SSH session: pipe the password via stdin and add
  `--unlock-from-stdin`. Once after creating a new certificate, also add `--allow-codesign`, so
  that codesign may use the signing key without a confirmation dialog.

---

## Optional: PhotoCraft add-on

**NV-AI for PhotoCraft** connects PhotoCraft to a local NV-AI. It needs PhotoCraft 0.10.0 or
newer: https://github.com/storytold/photocraft/releases/latest

- **Windows:** an optional component of the setup, included in the full installation (if the
  setup was built with the add-on). If PhotoCraft is not installed yet, the setup offers to open its download page; it
  also installs the Microsoft WebView2 runtime if it is missing. Start the add-on from the Start
  menu entry **NV-AI for PhotoCraft**. It finds NV-AI through `HKCU\Software\NV-AI` and starts
  it when needed.
- **macOS:** included in the DMG as **NV-AI für PhotoCraft**. It starts NV-AI by itself when
  needed; both run locally only.

The add-on talks to NV-AI through its REST API on `http://127.0.0.1:8100`, so it works the same
with NV-AI on Windows and with NV-AI for Mac. Its source code is in
[`photocraft-addon/`](../photocraft-addon/).
