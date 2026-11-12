# Installing NVAI-open

*Deutsch: [de/INSTALL.md](de/INSTALL.md)*

NVAI-open generates media locally on your own hardware:

- **Windows:** images, video with sound, music, 3D models and restored photos on your graphics card, with the Studio
  for whole videos, a web interface and an MCP server for Claude Code.
- **macOS:** a native app for Apple Silicon with images, video, music, photo restoration and the Studio.

Both offer the same REST API at `http://127.0.0.1:8100`.

- [Windows: install with the setup](#windows-install-with-the-setup)
- [macOS: install from the DMG](#macos-install-from-the-dmg)
- [Building from source](#building-from-source)
- [Optional: PhotoCraft add-on](#optional-photocraft-add-on)

---

## Windows: install with the setup

`NVAI-open-Setup-<version>.exe` needs neither Python nor git. It brings its own copy of uv and installs Python, ComfyUI
and PyTorch in the tested versions. It installs for the current user only, without administrator rights.

### Requirements

| | |
|---|---|
| **Windows** | Windows 10 (version 2004 or later) or Windows 11, 64-bit |
| **Graphics card** | NVIDIA, or AMD Radeon (experimental, see below); 8 GB of VRAM is workable, 12–16 GB is comfortable |
| **Driver** | NVIDIA 580.88 or newer (needed by PyTorch with CUDA 13): https://www.nvidia.com/drivers. AMD: Adrenalin 26.2.2 or newer |
| **Internet** | about 3 GB during setup (mostly PyTorch), plus 5–40 GB per model |
| **Disk** | about 10 GB for the program, plus room for the models |

The setup checks the graphics card and the driver and warns if it finds no suitable card or the driver is too old.

### AMD Radeon and several graphics cards (experimental)

- **AMD Radeon:** if the setup finds a Radeon and no NVIDIA card, it installs PyTorch with ROCm 10 from AMD's packages,
  checks it with a small computation on the card and falls back to ROCm 7.2.1 if that fails. Under "Models", "For your
  GPU" shows the matching versions: FP8 and bf16 on a Radeon RX 9000, INT8 on other Radeons. 3D needs NVIDIA. Nothing is
  measured on a real Radeon yet, so feedback in [#2](https://github.com/Mantux775/NVAI-open/issues/2) helps a lot.
  `install-runtime.ps1 -Gpu amd|nvidia` or `-Rocm 10.0|7.2` forces a choice.
- **Several NVIDIA cards:** everything runs on the strongest card. Under "Models" → "Graphics cards" (or with a click on
  a card in the header) you can give image models, language models and 3D a card of their own; the choice is stored in
  `gpus.json` in the data folder. In our test with two cards, splitting the work brought no gain
  ([issue #1](https://github.com/Mantux775/NVAI-open/issues/1#issuecomment-6373776729)).

### Windows SmartScreen

The setup is not code-signed, so Windows may show **"Windows protected your PC"**. Click **More info**, then
**Run anyway**.

### Installing

1. Run `NVAI-open-Setup-<version>.exe`.
2. Choose the program folder (default `%LOCALAPPDATA%\Programs\NV-AI`).
3. Choose the folders for data (images, settings, logs; default `%LOCALAPPDATA%\NV-AI`) and for models (default
   `%LOCALAPPDATA%\NV-AI\models`). A model has 5 to 40 GB, so a large drive makes sense. Both folders must be outside
   the program folder, so that your models and images survive an uninstall.
4. Choose the installation type. **Full installation** adds the 3D component (TripoSG; the model itself, 7.4 GB, is
   downloaded later) and the PhotoCraft add-on. **NVAI-open only** covers images, audio and video. **Custom** lets you
   pick.
5. The setup then installs Python, ComfyUI and PyTorch (about 3 GB) in a console window that closes by itself. This
   takes 5 to 20 minutes.

If the last step fails, the setup shows the path of `install.log`. You can retry later with **Repair NVAI-open** in
the Start menu.

### First steps

1. Open **NVAI-open** from the Start menu. Your browser shows the app at `http://127.0.0.1:8100`.
2. Under **Models**, download a model. Models that suit your graphics card are marked *recommended*.
3. Under **Generate**, enter a prompt. The first job after a start takes 30 to 60 seconds longer while the model loads.

**Quit NVAI-open** in the Start menu shuts everything down and frees the graphics card. To use NVAI-open from Claude
Code, see [CLAUDE_CODE.md](CLAUDE_CODE.md).

### FLUX 3 and LTX-2.5 (Hugging Face access)

Black Forest Labs (FLUX 3 Image Klein) and Lightricks (LTX-2.5) ask you to accept their license first. With a free
account at https://huggingface.co:

1. Accept the license at https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy and
   https://huggingface.co/Lightricks/LTX-2.5.
2. Create a token with read access at https://huggingface.co/settings/tokens.
3. Enter the token in NVAI-open under **Models**, in the "Hugging Face" box. The model card then shows whether access
   works.

Step by step with pictures: [HUGGINGFACE.md](HUGGINGFACE.md). Licenses: FLUX 3 commercially only below US$5 million
annual revenue, and every image must be reviewed before it is published; LTX-2.5 free below US$10 million.

### Models

No models are included; together they weigh several hundred gigabytes. Download them under **Models**, where each one
shows its size, memory needs and license. NVAI-open marks the right versions for your card as *recommended*:

| Graphics card | Images | Video | Photos (sharpen) |
|---|---|---|---|
| RTX 50 | Qwen-Image-2512, FLUX 3 Image Klein and Krea 2 in NVFP4, MOSS-Image INT8 | LTX-2.5 NVFP4 | SeedVR2 7B NVFP4 |
| RTX 20, 30, 40 | the same in INT8, plus Z-Image INT8 | LTX-2.5 INT8 | SeedVR2 7B INT8 |
| Radeon RX 9000 | FP8 and bf16 versions | LTX-2.5 INT8 | SeedVR2 7B FP8 |

For 3D the full installation includes TripoSG. TRELLIS.2 (with textures) needs an installation from source (see
[Optional: 3D workers](#optional-3d-workers)).

A model that is larger than the graphics memory still runs: ComfyUI streams parts from system memory. On a normal
connection that cost little (Krea 2 INT8 with 8 GB: 13.0 instead of 12.2 s), on a slow one such as a riser a lot. Every
image and video model is labeled *uncensored*, *partly censored* or *censored*, with the source in the tooltip.

### LoRAs (Hugging Face and Civitai)

"Models" → "Search models and LoRAs" also finds LoRAs, on Hugging Face and on Civitai. Before downloading, NVAI-open
reads the file header and tells which model a LoRA fits. Civitai needs your own API key for most downloads
(civitai.com → Settings → API Keys). A LoRA file you trained yourself goes in with "Models" → "Add LoRA file".

On the Generate page each matching LoRA appears under the selected model: tick it, set the strength (0.6–1.0 is usual)
and add its trigger words with "+ trigger". Wan 2.2 A14B LoRAs usually come as a high-noise and a low-noise file:
download both. Which models take LoRAs, the tested ones and the REST calls: [LORAS.md](LORAS.md).

Licenses and content of LoRAs are stated only on their pages; check them there before you publish anything.

### Storage locations

"Models" → "Storage locations" shows the data folder and the models folder with the free space. "Browse …" picks a new
folder, "Restart NVAI-open now" applies it. Existing files stay where they are: to take them along, quit NVAI-open,
move them and start it again.

### Cancelling

Every download and every generation can be cancelled, also while it waits in the queue: in the download bar, on the
Models and Generate pages, or with "Stop" in the header. A cancelled download keeps its finished files, and "Resume"
under "Models" downloads only what is missing. REST: `POST /api/jobs/{id}/cancel`.

### Reporting a problem

"Report a problem" at the top right: describe in a sentence what happened, and NVAI-open writes a report with the
version, Windows, graphics card, driver, installed models, the recent jobs and the ends of the logs. You see it before
passing it on. It is anonymized: names, paths, e-mail, IP and MAC addresses and tokens are replaced, and prompts and
images are left out. "Report on GitHub" opens a prefilled issue; drag the saved file into it.

### Logs and repair

The logs are in the data folder (default `%LOCALAPPDATA%\NV-AI`): `install.log` (setup), `nvai-server.log` (server)
and `comfyui.log` (generation). **Repair NVAI-open** in the Start menu installs Python, ComfyUI and PyTorch again. The
settings are in the registry under `HKCU\Software\NV-AI`; if another program uses port 8100, enter a different `Port`
there.

### Updating and uninstalling

- **Update:** run the newer setup. It stops a running NVAI-open first and keeps your data and model folders. (Up to
  0.5.7 the app was called NV-AI; folders and settings kept that name.)
- **Uninstall:** **Settings → Apps → NVAI-open**. It removes the program folder and then asks whether to delete the
  data and models too. Answer **No** to keep them.

---

## macOS: install from the DMG

NVAI-open for Mac is a native app for Apple Silicon. It offers the same REST API as on Windows, so the PhotoCraft add-on
and Claude Code work with it the same way.

### Requirements

| | |
|---|---|
| **Mac** | Apple Silicon, macOS 15 or later (LTX-2.3 and LTX-2.5 need macOS 26.3) |
| **Memory** | 8 GB for images and short videos, 16 GB or more is comfortable |
| **Disk** | about 1 GB for the app, plus about 10 GB for FLUX.2 Klein |

### Installing

The DMG is signed and notarized by Apple.

1. Open `NVAI-open-<version>.dmg` and drag **NVAI-open** into your Applications folder; for PhotoCraft also the add-on
   app **NVAI-open für PhotoCraft**.
2. Open NVAI-open. Under **Models**, download FLUX.2 Klein (about 10 GB, once): the 8-bit version from 24 GB of memory,
   below that the 4-bit version.
3. Under **Generate**, enter a prompt. The first image takes longer while the model loads.

The server starts with the app, independently of the window, and listens only on `127.0.0.1:8100`.

### What runs on the Mac

| What | Models | Memory |
|---|---|---|
| Images | FLUX.2 Klein 4B (generate, edit, fill, extend, up to 3 reference images), Z-Image Turbo, Stable Diffusion as Core ML | from 8 GB |
| Video | LTX-Video 2B from text or a start image, no sound | from 8 GB, up to 768 × 512 × 97 frames |
| | LTX-Video 13B | from 16 GB (4 bit) or 24 GB (8 bit) |
| | LTX-2.3 and LTX-2.5 with sound | from 32 and 64 GB, macOS 26.3 |
| Music and sounds | Stable Audio 3 | from 8 GB |
| Old photos | FLUX.2 Klein, "Automatic" with Qwen3.5 4B, sharpening with SeedVR2 3B | from 8 GB |
| Expand prompt | the Qwen3-4B text encoder of FLUX.2 Klein, no extra download | from 8 GB |

Only what fits a Mac mini M1 with 8 GB is measured: a 512 × 512 image with FLUX.2 Klein 4-bit in about 40 s, 30 s of
music in about 13 s, 2 s of video at 768 × 512 in about 95 s. The bigger video models are recommended by memory from
their authors' figures, not measured.

Qwen-Image and FLUX 3 do not run on the Mac; there are no native, free ports for them yet. Core ML models have a fixed
size; other sizes are stretched.

### Files and feedback

- Data: `~/Library/Application Support/NV-AI`. Log: `~/Library/Logs/NV-AI/nvai.log`.
- **Settings → "Report a problem"** writes an anonymized report like on Windows and opens a prefilled issue.

---

## Building from source

### Windows development setup

| | |
|---|---|
| **NVIDIA graphics card** | 8 GB of VRAM is workable, 12–16 GB is comfortable; driver 580.88 or newer |
| **Windows 10/11** | the scripts are PowerShell |
| **git** | https://git-scm.com/download/win |
| **uv** | `winget install astral-sh.uv`, creates the Python environments |
| **Node.js** | `npm` builds the web interface |
| **Disk** | 30 GB for the installation, plus 5–40 GB per model |

```powershell
git clone https://github.com/Mantux775/NVAI-open.git
cd NVAI-open
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

The script fetches ComfyUI at the tested version, creates two Python environments (the server, and the GPU backend with
PyTorch for CUDA 13), builds the web interface and lists the models that fit your card. Expect 10–20 minutes.

```powershell
scripts\start.ps1     # then open http://127.0.0.1:8100
scripts\stop.ps1      # stops NVAI-open and ComfyUI
```

ComfyUI starts with the first job (about 30 s, once). If port 8100 is busy, `start.ps1` names the process instead of
starting a second server.

**Access from other devices:** `scripts\start.ps1 -Lan` also listens on the network. Other devices then send a token in
the `X-NVAI-Token` header (from `$env:NVAI_TOKEN` or `data\api_token`, which `-Lan` creates if needed). The connection
is plain HTTP, so from outside use a VPN.

**Claude Code:**

```powershell
claude mcp add --scope user nvai -- "<repository folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

#### Optional: 3D workers

```powershell
scripts\setup_triposg.ps1     # geometry, MIT license
scripts\setup_trellis2.ps1    # geometry and PBR textures, needs a C++ compiler
```

Clone the upstream repository into `external\triposg` or `external\trellis2` first. TRELLIS.2 compiles a CUDA extension
and needs the Visual Studio 2022 Build Tools with the C++ tools.

#### Repository layout

```
server/             server (FastAPI), MCP server, 3D workers (server/workers)
frontend/           web interface (React/Vite), built into frontend/dist/
scripts/            setup, start, stop
packaging/windows/  Windows setup (Inno Setup)
packaging/tools/    release helpers
mac/NVAIMac/        NVAI-open for Mac (SwiftUI)
photocraft-addon/   PhotoCraft add-on
docs/               documentation
```

### Building the Windows setup

```powershell
cd frontend; npm install; npm run build; cd ..
packaging\windows\build-setup.ps1 [-Addon <folder>]
```

You need Inno Setup 6 (`winget install JRSoftware.InnoSetup --scope user`), uv and Python 3 on the `PATH`, and the
built web interface. The script collects the server code, the web interface, ComfyUI and TripoSG at pinned versions,
uv and the locked package lists from `packaging\windows\locks`, then runs Inno Setup. The result is
`packaging\windows\build\NVAI-open-Setup-<version>.exe`; the version comes from `server\nvai\__init__.py`.

- The PhotoCraft add-on becomes an optional component if a built add-on folder is found (`-Addon`, `$env:NVAI_ADDON_DIR`
  or `photocraft-addon\dist\addon`).
- On the target PC the setup installs exactly the package versions in `locks\`, checked by their hashes.
- The bundled `.ps1` scripts must be pure ASCII (Windows PowerShell 5.1 reads them as ANSI); the build script checks it.

### Building the Mac app

You need a Mac with Apple Silicon, Xcode with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`,
once) and XcodeGen. Build with **xcodebuild**, not `swift build`: only Xcode compiles MLX's Metal shaders.
`project.yml` is the XcodeGen spec, package versions are pinned in `Package.resolved`.

The scripts in `mac/NVAIMac/scripts` expect the project in `~/NVAIMac` on the Mac:

| Script | What it does |
|---|---|
| `sync.sh` | From Windows (Git Bash): copies the sources over SSH to `~/NVAIMac` on a Mac reachable as `macmini` and runs `xcodegen generate` there |
| `build.sh` | builds `~/NVAIMac/dd/Build/Products/Release/NVAI-open.app` (Release, arm64, ad-hoc signed) |
| `release.sh` | builds the DMG |

Working directly on a Mac: copy `mac/NVAIMac` to `~/NVAIMac`, run `xcodegen generate` there and copy `Package.resolved`
to `NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. Then `zsh ~/NVAIMac/scripts/build.sh`.

A test run with its own port: `open -n ~/NVAIMac/dd/Build/Products/Release/NVAI-open.app --args -serverPort 8110`.
`NVAI-open --snapshot <png> [--tab studio|generate|history|models|settings] --quit` saves a picture of the window
without a screen.

#### Release DMG

`zsh ~/NVAIMac/scripts/release.sh` builds `~/NVAIMac/release/NVAI-open-<version>.dmg` with the app, the PhotoCraft
add-on (if the environment variable `ADDON_DIR` points to the folder with its `build-app.sh`) and a getting-started
text. With a "Developer ID Application"
certificate the apps and the DMG are signed, notarized and stapled (an App Store Connect API key is needed for
`notarytool`); without one the DMG is only ad-hoc signed, for internal tests. In an SSH session with a locked keychain,
pipe the password in and add `--unlock-from-stdin`.

---

## Optional: PhotoCraft add-on

**NVAI-open for PhotoCraft** connects PhotoCraft to a local NVAI-open. It needs PhotoCraft 0.10.0 or newer:
https://github.com/storytold/photocraft/releases/latest

- **Windows:** part of the full installation. If PhotoCraft is missing, the setup offers its download page and
  installs the WebView2 runtime if needed. Start the add-on from the Start menu (**NVAI-open for PhotoCraft**); it
  starts NVAI-open when needed.
- **macOS:** in the DMG as **NVAI-open für PhotoCraft**. It also starts NVAI-open by itself.

The add-on talks to NVAI-open over the REST API at `http://127.0.0.1:8100`, so it works the same on Windows and on the
Mac. Its source code is in [`photocraft-addon/`](../photocraft-addon/).
