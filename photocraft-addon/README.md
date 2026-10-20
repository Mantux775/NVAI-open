# NV-AI for PhotoCraft – local AI as the main AI in PhotoCraft

*Deutsch: [README.de.md](README.de.md)*

A slim panel next to [PhotoCraft](https://github.com/storytold/photocraft) that brings the local image
generation of **NV-AI** (your own GPU, no cloud) into everyday image editing – similar to
Photoshop's "Generative Fill":

| Mode | What happens |
|---|---|
| **Fill** | The selection is regenerated to match its surroundings (inpainting). Without a prompt the surroundings simply continue – handy for retouching. Without a selection, transparent edges get filled, e.g. after *Image › Canvas Size* with a transparent extension (outpainting); a short prompt describing the scene helps there. |
| **Generate** | A new image in the selection – or on the whole canvas if nothing is selected. |
| **Refine** | The selection (or the whole image) is re-rendered. Image-to-image models use the *strength* to set how much changes; reference-edit models such as **FLUX 3** take the prompt as an instruction: say what changes and what stays ("Replace the rope handles with iron handles; keep everything else unchanged."). |

Every result lands in the document as **its own layer with a layer mask made from the selection** –
nothing is overwritten destructively. With several variants, a click in the panel swaps the layer,
**+** adds a variant as an extra layer. The selection stays active, so the next attempt is one
shortcut away.

There are two front ends with the same behaviour:

- **Windows:** a Python bridge with an HTML panel in its own window (`bridge/`, `panel/`). It ships as
  an optional component of the NV-AI setup.
- **macOS:** the native SwiftUI app "NV-AI for PhotoCraft" (`MacApp/`) on top of the Swift package
  `PhotoCraftKit/`. It ships in one DMG together with "NV-AI for Mac".

## How it works

```
PhotoCraft (started with --control)         NV-AI (:8100)
        ▲   JSON lines over 127.0.0.1:47821        ▲  REST (API version 1)
        │   (token protected)                      │
        └──────── bridge (:8120) / Mac app ────────┘
```

1. **Capture** – a reduced working copy of the active document is created for a moment; the area and
   the selection mask are exported from it into an exchange folder. Your document and its history
   stay untouched.
2. **Compute** – area and mask go to NV-AI at working size (about 1 megapixel).
3. **Place** – the result is inserted as a layer at exactly the right position and gets the
   selection as its mask.

PhotoCraft itself (as of 0.10) has **no** generative AI, and its plug-ins run in a sandbox without
network access. Its automation control channel is therefore the clean way in.

## Requirements

- **PhotoCraft 0.10 or newer** – the version the control channel was measured with. The panel finds
  it on its own (Windows: the *App Paths* entry of its installer; macOS: its bundle ID). If it is
  missing or older, the panel shows a download button for the
  [latest release](https://github.com/storytold/photocraft/releases/latest).
- **NV-AI 0.2 or newer** with masks for *Fill*:
  - Windows: installed by the NV-AI setup (`HKCU\Software\NV-AI`), or a development checkout of NV-AI
    in the folder above this one (or a sibling folder `NV-AI`).
  - macOS: "NV-AI for Mac" on `http://127.0.0.1:8100`; the panel can start it with one click.
  - An NV-AI on another computer works too (address and token, see below).
- **Windows:** Microsoft Edge WebView2 Runtime for the panel window (without it the panel opens in the
  default browser). **macOS:** 14 or newer, Apple silicon.

## Language

English is the default, German is an option: the language selector at the bottom right of the
panel (*Automatic* follows the system language: German only if the system is German), or
*Settings* in the Mac app. The choice is stored as `language` in `settings.json`. NV-AI receives the
same language as `Accept-Language` and returns its model texts and error messages accordingly.

## Using it

1. Save and close a PhotoCraft that was started normally – it cannot be connected afterwards.
2. Start **NV-AI for PhotoCraft**. On Windows this also starts NV-AI if needed and PhotoCraft with
   its control channel; on the Mac the panel offers buttons for both.
3. Make a selection in PhotoCraft, choose mode and prompt in the panel, press **Ctrl + Enter**
   (Mac: **⌘ + Return**).

Tips:

- Detailed English prompts in full sentences work best. Below the prompt the panel shows the short
  guide NV-AI provides for the selected model.
- Only a few words? **✨ Expand prompt** below the prompt lets NV-AI write a full image description
  from them (about 15 s, needs NV-AI 0.4 or newer with FLUX 3 downloaded).
  Read it and remove what the upsampler invented before you start; "Back to my prompt" undoes it.
  Windows panel only for now.
- If the model active in NV-AI does not fit the mode, the panel picks a suitable one and says so.
- For **new objects** when filling, use a full model; fast distilled models (cfg 1) mostly continue
  the surroundings – good for retouching.
- *Advanced › Native model resolution* renders at the model's training resolution: more detail,
  about twice the time. Models with a fixed square format (Core ML on the Mac) always render
  square; generated images are cropped to the selection, never stretched.
- **Esc** cancels a running job – only your own; NV-AI can be used by others in parallel.
- The pin at the top right keeps the panel above PhotoCraft.

## Limitations

- While the connected PhotoCraft is running, **double-clicking a file in Explorer** opens a second
  PhotoCraft window without the connection (`--control` disables PhotoCraft's single instance).
  Open files via *File › Open* or drag & drop instead.
- The models work at about one megapixel. Very large selections are upscaled accordingly and look
  softer – fill them in parts.
- While a job captures or places, a helper tab flashes briefly in PhotoCraft.

## NV-AI on another computer

NV-AI does not have to run on the same machine (e.g. via Tailscale). Address and token go into
`settings.json` in the data folder (Windows: `%LOCALAPPDATA%\ArtCraft-LocalAI\`, macOS:
`~/Library/Application Support/ArtCraft-LocalAI/`) or into the environment variables `NVAI_URL` /
`NVAI_TOKEN`; the Mac app also has fields for them:

```json
{"nvai_url": "http://pc-name:8100", "nvai_token": "…", "language": "auto"}
```

The token is sent as the header `X-NVAI-Token`. NV-AI needs no token from its own computer, and one
for everything except `/api/health` and `/api/version` from other computers. On Windows, NV-AI only
admits other computers when started with `scripts\start.ps1 -Lan`; its token is in `data\api_token`.
After entering it, **Check again** is enough – no restart needed. A portable PhotoCraft is entered
as `"photocraft_exe"`.

## Troubleshooting

| Message | Cause |
|---|---|
| "PhotoCraft is not installed" | Get PhotoCraft with the panel's download button (`…-windows-x64.msi` / `…-macos-universal.dmg`) |
| "PhotoCraft … is older than 0.10.0" | The control channel is not tested with older versions – please update |
| "NV-AI is not installed on this PC" | Neither the NV-AI setup (`HKCU\Software\NV-AI`) nor a development checkout was found |
| "No image model is installed in NV-AI yet" | Fresh installation: load an image model in NV-AI (**Open NV-AI**); the panel notices it by itself |
| "PhotoCraft is already running without the NV-AI connection" | Close the normally started PhotoCraft, then start it again from the panel |
| "does not know masks yet" | NV-AI without mask support (before 0.2.0) |
| "the token is missing or wrong" | Remote NV-AI: put the token into `settings.json`, then **Check again** |
| "only accepts requests from its own computer" | Remote NV-AI runs without `-Lan` – start it there with `scripts\start.ps1 -Lan` |
| "speaks API version …" | Bridge and NV-AI do not match – update the older one |
| "The target document … is no longer open" | The document was closed or resized during the job |

The bridge log is `logs\bridge.log` in the data folder; at start it names the NV-AI and PhotoCraft
it found. The Mac app writes `logs/mac-app.log` and has a self-test:
`"NV-AI for PhotoCraft.app/Contents/MacOS/NVAIPhotoCraft" --selftest`.

## Development

Windows (Python 3.12, [uv](https://docs.astral.sh/uv/) recommended):

```powershell
scripts\setup.ps1                 # venv + dependencies + tests
scripts\start.ps1                 # bridge, NV-AI and PhotoCraft, panel window
python -m bridge --server         # bridge only, panel at http://127.0.0.1:8120
python -m pytest                  # tests (incl. golden data and the NV-AI contract)
python tools\build_addon.py --check   # assemble dist\addon for the NV-AI setup and verify it
```

macOS (Swift 6 toolchain, Xcode command line tools):

```sh
cd PhotoCraftKit && swift test
cd MacApp && ./build-app.sh [--sign "Developer ID Application: …"] [target folder]
```

- **Behaviour lives in Python first.** `bridge/planning.py` and `bridge/imaging.py` are the reference;
  `python tools/export_golden.py` writes `golden/*.json` (and the copy for the Swift tests) and
  `PhotoCraftKit` checks itself against it. The control channel is specified in
  [`docs/mac-port.md`](docs/mac-port.md), the Windows setup integration in
  [`docs/windows-installer.md`](docs/windows-installer.md) (both in German).
- **NV-AI contract:** `contract/nvai-openapi.json` (API version 1). Both clients check
  `/api/version` before every job; contract tests reject request fields the contract does not know.
- **Translations:** every visible text is written as `t("Deutsch", "English")` – in Python
  (`bridge/i18n.py`), JavaScript (`panel/panel.js`; static HTML texts carry `data-de`) and Swift
  (`PhotoCraftKit/Localization.swift`).
- `tools/chain_probe.py` checks the complete control chain against a PhotoCraft test instance (standard
  library only); `tools/fake_photocraft.py` replays the measured behaviour for tests.
- Code comments are mostly in German.

## Repository layout

| Path | Contents |
|---|---|
| `bridge/` | Windows bridge: PhotoCraft client, NV-AI client, imaging, planning, jobs, HTTP server, window |
| `panel/` | Panel UI (HTML/CSS/JS, no build step) |
| `PhotoCraftKit/` | Swift package: control client, NV-AI client, Core Image processing, planning, workflow |
| `MacApp/` | SwiftUI app "NV-AI for PhotoCraft" |
| `golden/`, `contract/` | Golden test data from the Python reference; NV-AI API contract |
| `tests/`, `tools/`, `scripts/` | Python tests, developer tools, Windows developer scripts |
| `docs/` | Specifications (German) |

The control token (`photocraft-control.token`) allows full remote control of PhotoCraft, so it lives
only in the user's data folder. PhotoCraft may read and write files via remote control only inside
the exchange folder.

## License

MIT – see the license of the repository. Third-party packages and their licenses:
[THIRD_PARTY.md](THIRD_PARTY.md).
