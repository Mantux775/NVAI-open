# NVAI-open for PhotoCraft – local AI as the main AI in PhotoCraft

*Deutsch: [README.de.md](README.de.md)*

A slim panel next to [PhotoCraft](https://github.com/storytold/photocraft) that brings the local image
generation of **NVAI-open** (your own GPU, no cloud) into everyday image editing – similar to
Photoshop's "Generative Fill":

| Mode | What happens |
|---|---|
| **Fill** | The selection is regenerated to match its surroundings (inpainting). Without a prompt the surroundings simply continue – handy for retouching. Without a selection, transparent edges get filled, e.g. after *Image › Canvas Size* with a transparent extension (outpainting); a short prompt describing the scene helps there. The **Extend** mode does this in one step. With NVAI-open 0.5.6 or later FLUX 3 fills too and is chosen unless you pick another model: NVAI-open greys the area, lets FLUX 3 paint it and puts back only the selection, aligned. In testing it removed crates with the cobblestones running on; to change something that is already there, such as the lettering on a sign, **Refine** with FLUX 3 kept position and angle better. |
| **Extend** | Outpainting (since 0.4.3 its own mode): enter left, top, right, bottom in pixels (or pick "wider", "taller", "downwards", "all around"); the add-on enlarges the canvas and paints the new border to match. Every model that can extend is offered, FLUX 3 first: it gave seamless transitions in testing, while Qwen left a hard edge at the old border. On the Mac it is FLUX.2 Klein with a mask; there the transition stays softer and can remain visible as a blurred strip at the old border. Needs NVAI-open 0.5.4 or later (Mac: 0.4.3). |
| **Generate** | A new image in the selection – or on the whole canvas if nothing is selected. |
| **Refine** | The selection (or the whole image) is re-rendered. Image-to-image models use the *strength* to set how much changes; reference-edit models such as **FLUX 3** take the prompt as an instruction: say what changes and what stays ("Replace the rope handles with iron handles; keep everything else unchanged."). |
| **Restore** | For old photos (since 0.4.6, needs NVAI-open 0.5.11): **remove damage** (scratches, dust, tears, stains), **colorize** and **sharpen and enlarge** with SeedVR2, each step optional, for the selection or the whole image. *Automatic* (default) lets NVAI-open's image model check the photo for water stains and crack networks and picks *Thorough* or *Gentle* (as expected on 20 of 21 test photos). *Thorough* redraws the whole photo with FLUX 3: cracks, fine scratches, water stains and fading go, faces can change slightly from variant to variant. *Gentle* only replaces the damaged spots and keeps sharpness, faces and detail exactly as in the photo (contrast and fading come from FLUX 3). Choose by the kind of damage: overall aging (water stains, crack networks, grain, fading) → *Thorough*; separate damage on an otherwise good photo (dust, scratches, tears, light leaks) → *Gentle*. Colorizing takes only the color from FLUX 3; known colors in the prompt ("her dress is dark red") make it more accurate. A grayscale document that gets colorized lands in a new RGB document "<name> – color" with the original as the bottom layer (PhotoCraft does not let add-ons change the color mode). Enlarging scales the whole document, so it only works without a selection. Measured on an RTX 5060 Ti: two variants of a 1 MP photo, repaired gently, colorized and enlarged 2×, in about 3 minutes. |

Every result lands in the document as **its own layer with a layer mask made from the selection** –
nothing is overwritten destructively. With several variants, a click in the panel swaps the layer,
**+** adds a variant as an extra layer. The selection stays active, so the next attempt is one
shortcut away.

There are two front ends with the same behaviour:

- **Windows:** a Python bridge with an HTML panel in its own window (`bridge/`, `panel/`). It ships as
  an optional component of the NVAI-open setup.
- **macOS:** the native SwiftUI app "NVAI-open for PhotoCraft" (`MacApp/`) on top of the Swift package
  `PhotoCraftKit/`. It ships in one DMG together with "NVAI-open for Mac".

## How it works

```
PhotoCraft (started with --control)         NVAI-open (:8100)
        ▲   JSON lines over 127.0.0.1:47821        ▲  REST (API version 1)
        │   (token protected)                      │
        └──────── bridge (:8120) / Mac app ────────┘
```

1. **Capture** – a reduced working copy of the active document is created for a moment; the area and
   the selection mask are exported from it into an exchange folder. Your document and its history
   stay untouched.
2. **Compute** – area and mask go to NVAI-open at working size (about 1 megapixel).
3. **Place** – the result is inserted as a layer at exactly the right position and gets the
   selection as its mask.

PhotoCraft itself (as of 0.10) has **no** generative AI, and its plug-ins run in a sandbox without
network access. Its automation control channel is therefore the clean way in.

## Requirements

- **PhotoCraft 0.10 or newer** – the version the control channel was measured with. The panel finds
  it on its own (Windows: the *App Paths* entry of its installer; macOS: its bundle ID). If it is
  missing or older, the panel shows a download button for the
  [latest release](https://github.com/storytold/photocraft/releases/latest).
- **NVAI-open 0.2 or newer** with masks for *Fill*:
  - Windows: installed by the NVAI-open setup (`HKCU\Software\NV-AI`), or a development checkout of NVAI-open
    in the folder above this one (or a sibling folder `NVAI-open`).
  - macOS: "NVAI-open for Mac" on `http://127.0.0.1:8100`; the panel can start it with one click.
  - An NVAI-open on another computer works too (address and token, see below).
- **Windows:** Microsoft Edge WebView2 Runtime for the panel window (without it the panel opens in the
  default browser). **macOS:** 14 or newer, Apple silicon.

## Language

English is the default, German is an option: the language selector at the bottom right of the
panel (*Automatic* follows the system language: German only if the system is German), or
*Settings* in the Mac app. The choice is stored as `language` in `settings.json`. NVAI-open receives the
same language as `Accept-Language` and returns its model texts and error messages accordingly.

## Using it

1. Save and close a PhotoCraft that was started normally – it cannot be connected afterwards.
2. Start **NVAI-open for PhotoCraft**. On Windows this also starts NVAI-open if needed and PhotoCraft with
   its control channel; on the Mac the panel offers buttons for both.
3. Make a selection in PhotoCraft, choose mode and prompt in the panel, press **Ctrl + Enter**
   (Mac: **⌘ + Return**).

Tips:

- Detailed English prompts in full sentences work best. Below the prompt the panel shows the short
  guide NVAI-open provides for the selected model.
- Only a few words? **✨ Expand prompt** below the prompt lets NVAI-open write a full image description
  from them. Windows: about 15 s, needs NVAI-open 0.4 or newer with FLUX 3 downloaded. Mac: about
  25 s on an M1 with 8 GB, needs NVAI-open for Mac 0.4 or newer with FLUX.2 Klein downloaded (its text
  encoder writes the description, no extra download). Read it and remove what was invented before
  you start; "Back to my prompt" undoes it.
- If the model active in NVAI-open does not fit the mode, the panel picks a suitable one and says so.
- For **new objects** when filling, use a full model; fast distilled models (cfg 1) mostly continue
  the surroundings – good for retouching.
- *Advanced › Native model resolution* renders at the model's training resolution: more detail,
  about twice the time. Models with a fixed square format (Core ML on the Mac) always render
  square; generated images are cropped to the selection, never stretched.
- **Esc** cancels a running job – only your own; NVAI-open can be used by others in parallel.
- While NVAI-open downloads a model, the panel shows it with its progress and a ✕ to cancel it
  (needs NVAI-open 0.5.2 or Mac 0.4.2 to stop mid-file; older versions cancel all downloads).
- The pin at the top right keeps the panel above PhotoCraft.

## Limitations

- While the connected PhotoCraft is running, **double-clicking a file in Explorer** opens a second
  PhotoCraft window without the connection (`--control` disables PhotoCraft's single instance).
  Open files via *File › Open* or drag & drop instead.
- The models work at about one megapixel. Very large selections are upscaled accordingly and look
  softer – fill them in parts.
- While a job captures or places, a helper tab flashes briefly in PhotoCraft.
- **Restore:** small marks that FLUX 3 leaves out, such as a hyphen in a caption, disappear in both
  modes – check lettering. Color can bleed across edges of equal brightness.

## NVAI-open on another computer

NVAI-open does not have to run on the same machine (e.g. via Tailscale). Address and token go into
`settings.json` in the data folder (Windows: `%LOCALAPPDATA%\ArtCraft-LocalAI\`, macOS:
`~/Library/Application Support/ArtCraft-LocalAI/`) or into the environment variables `NVAI_URL` /
`NVAI_TOKEN`; the Mac app also has fields for them:

```json
{"nvai_url": "http://pc-name:8100", "nvai_token": "…", "language": "auto"}
```

The token is sent as the header `X-NVAI-Token`. NVAI-open needs no token from its own computer, and one
for everything except `/api/health` and `/api/version` from other computers. On Windows, NVAI-open only
admits other computers when started with `scripts\start.ps1 -Lan`; its token is in `data\api_token`.
After entering it, **Check again** is enough – no restart needed. A portable PhotoCraft is entered
as `"photocraft_exe"`.

## Troubleshooting

| Message | Cause |
|---|---|
| "PhotoCraft is not installed" | Get PhotoCraft with the panel's download button (`…-windows-x64.msi` / `…-macos-universal.dmg`) |
| "PhotoCraft … is older than 0.10.0" | The control channel is not tested with older versions – please update |
| "NVAI-open is not installed on this PC" | Neither the NVAI-open setup (`HKCU\Software\NV-AI`) nor a development checkout was found |
| "No image model is installed in NVAI-open yet" | Fresh installation: load an image model in NVAI-open (**Open NVAI-open**); the panel notices it by itself |
| "PhotoCraft is already running without the NVAI-open connection" | Close the normally started PhotoCraft, then start it again from the panel |
| "does not know masks yet" | NVAI-open without mask support (before 0.2.0) |
| "the token is missing or wrong" | Remote NVAI-open: put the token into `settings.json`, then **Check again** |
| "only accepts requests from its own computer" | Remote NVAI-open runs without `-Lan` – start it there with `scripts\start.ps1 -Lan` |
| "speaks API version …" | Bridge and NVAI-open do not match – update the older one |
| "The target document … is no longer open" | The document was closed or resized during the job |

The bridge log is `logs\bridge.log` in the data folder; at start it names the NVAI-open and PhotoCraft
it found. The Mac app writes `logs/mac-app.log` and has a self-test:
`"NVAI-open for PhotoCraft.app/Contents/MacOS/NVAIPhotoCraft" --selftest`.

## Development

Windows (Python 3.12, [uv](https://docs.astral.sh/uv/) recommended):

```powershell
scripts\setup.ps1                 # venv + dependencies + tests
scripts\start.ps1                 # bridge, NVAI-open and PhotoCraft, panel window
python -m bridge --server         # bridge only, panel at http://127.0.0.1:8120
python -m pytest                  # tests (incl. golden data and the NVAI-open contract)
python tools\build_addon.py --check   # assemble dist\addon for the NVAI-open setup and verify it
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
- **NVAI-open contract:** `contract/nvai-openapi.json` (API version 1). Both clients check
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
| `bridge/` | Windows bridge: PhotoCraft client, NVAI-open client, imaging, planning, jobs, HTTP server, window |
| `panel/` | Panel UI (HTML/CSS/JS, no build step) |
| `PhotoCraftKit/` | Swift package: control client, NVAI-open client, Core Image processing, planning, workflow |
| `MacApp/` | SwiftUI app "NVAI-open for PhotoCraft" |
| `golden/`, `contract/` | Golden test data from the Python reference; NVAI-open API contract |
| `tests/`, `tools/`, `scripts/` | Python tests, developer tools, Windows developer scripts |
| `docs/` | Specifications (German) |

The control token (`photocraft-control.token`) allows full remote control of PhotoCraft, so it lives
only in the user's data folder. PhotoCraft may read and write files via remote control only inside
the exchange folder.

## License

MIT – see the license of the repository. Third-party packages and their licenses:
[THIRD_PARTY.md](THIRD_PARTY.md).
