# Using NVAI-open from Claude Code

NVAI-open includes an MCP server, `nvai`, that makes local media generation on your own NVIDIA GPU
available to Claude Code: images, audio, video and 3D meshes for game assets, as a replacement
for paid cloud generation. The MCP server is a thin client of the NVAI-open REST server, so the web
UI and Claude Code behave identically and share the same job queue.

This guide covers setup, the tools, and practical advice on model choice, prompts, sizes and
settings. Run times were measured on an RTX 5060 Ti 16 GB. The advice is written so that you can
also paste the parts you need into a project's `CLAUDE.md`.

## Setup

### The server must be running

All tools talk to `http://127.0.0.1:8100`. If the server is not running, every tool fails.

- **Windows setup:** Start menu → **NVAI-open** starts it, **Quit NVAI-open** shuts it down.
- **Source checkout:**

```powershell
scripts\start.ps1        # reports if one is already running
scripts\stop.ps1         # stops NVAI-open and ComfyUI specifically
```

**Always call `health` first.** It shows in one go whether the GPU backend is running, which
model is active per category, how full the queues are, and whether the 3D worker is set up.

The GPU backend (ComfyUI) starts automatically with the first job — this costs ~30 s once.
Don't treat it as an error.

### Registering the MCP server

Register the server once at user scope, so that it is available in every Claude Code project:

```
claude mcp add --scope user nvai -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

`<install folder>` is the repository folder of a source checkout, or the program folder of the
Windows setup (default `%LOCALAPPDATA%\Programs\NV-AI`).

With the Windows setup, also pass your data folder. The MCP server builds the file paths it
returns from `NVAI_DATA_DIR` and otherwise assumes `data` inside the install folder, which is not
where the setup keeps its data (default `%LOCALAPPDATA%\NV-AI`):

```
claude mcp add --scope user nvai -e "NVAI_DATA_DIR=<data folder>" -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

If NVAI-open listens on a port other than 8100, pass its address the same way, for example
`-e "NVAI_API_URL=http://127.0.0.1:8101"`.

After an NVAI-open update, a running Claude Code session only sees the new tool descriptions after
`/mcp` and reconnecting.

## Tools

| Tool | Purpose |
|---|---|
| `health` | Always first. Backend, active models, queues |
| `list_models` | Catalog; `kind=` filters, `detailed=true` adds pros/cons and `features` |
| `download_model` / `delete_model` / `set_active_model` | Model management |
| `generate_image` | Image → file paths |
| `list_models(kind="lora")` | Downloaded LoRAs with their family and trigger words; pass them as `loras=[{model_id, strength}]` to `generate_image` / `generate_video` (the model's `lora_bases` says which fit) |
| `expand_prompt` | A few words → full prompt for every image model; `target` = video, video_sound, video_start, sfx, music or 3d for the other kinds (needs FLUX 3 downloaded) |
| `generate_audio` | SFX or music → file paths |
| `generate_video` | Short clip → file paths |
| `image_to_3d` | Image asset → GLB mesh |
| `text_to_3d` | Text → image → GLB mesh in one go |
| `restore_image` | Old photo → repaired, colorized and/or sharpened photo (since 0.5.11) |
| `list_assets` / `delete_asset` / `clear_history` | History |
| `copy_asset` | Copy an asset to `Assets/Generated/` or similar |
| `studio_*` | Studio projects: compose scenes, generate them, conform, cut and export a whole video (since 0.5.13, see [Studio](#studio-whole-videos-from-scenes-since-0513)) |

All `generate_*` tools **block until done** and return absolute file paths.

## Workflow

1. `health` — is everything running, is a model of the needed category active?
2. If one is missing: `list_models(kind=...)` → `download_model` → `set_active_model`
3. Generate
4. `copy_asset` into the target project, or pass the path straight to `Unity_ImportExternalModel`

When a model is missing, **don't guess** — `list_models` shows size, VRAM requirement and
license. Downloads are several GB; ask the user first.

## Recommended settings at a glance

The short version of everything below, as measured on an RTX 5060 Ti 16 GB. The web UI shows the same
list per tab under **Recommended settings** (since 0.5.11); keep both in step when a new finding comes in.

| Task | Recommended | Why (measured) |
|---|---|---|
| Final image asset, text in the image | `qwen-image-2512-nvfp4`, 50 steps, full English sentences, text in quotation marks | Letter-perfect crate lettering; rope handles drawn through drilled holes where Lightning laid them on the wood |
| Edit an image, keep a character consistent | `flux3-klein-nvfp4` with `reference_asset_ids`; say what changes and what stays | Only the handles changed, the rest stayed; 13–30 s |
| Photographic look | `krea2-turbo-nvfp4`, state the framing ("medium shot from the waist up, his whole head inside the frame") | Without the framing the head was cut off in 3 of 3 images, with it in 0 of 2; ~20 s |
| Poster, sign, graphic with text, free to sell | `moss-image-sft-int8` (Apache-2.0), 50 steps; describe the finished image, text in quotation marks with position and typeface | Text letter-perfect in every test; rope handles through drilled holes in 3 of 3 with 50 steps, 2 of 3 with 25; ~51 s |
| Size | Standing figure 832 × 1216, vehicle 1216 × 832, object 1024² | In a square, figures lose their feet more often |
| Choosing | `batch_size=4`, compare at full resolution | One model load instead of four; anatomy errors are a failure rate |
| Video | LTX-2.5, one present-tense paragraph, loud sound sources named | 5 s 720p in ~93 s; sounds described as soft came out at −41 to −52 LUFS |
| Fixed video framing | "Static camera, a locked-off medium shot; the framing stays exactly as in the first frame." | "stays still" pushed in to an extreme close-up |
| Video loop | `loop=True` only with a still camera | With a push-in the loop fell apart in the last frames |
| Video from several shots | Studio: one scene per shot, a `chain` marker where two shots must join, conform, export `youtube-1080p` | The chained clip started with the same knight in the same pose; 9 s exported in 4.1 s with NVENC at −14.6 LUFS |
| Explainer video with a presenter | Studio: start images with FLUX 3 in the video size (more shots of the same person via `reference_asset_ids`) as `params.image_asset_id`, the spoken line in the LTX prompt at about 2 words per second, `params.quality="dfr"` only for shots with a face, title cards as Qwen image scenes at 1664 × 928, music on A2 lowered with `gain_db` | Same face, glasses, hair and clothing in 4 of 4 reference images; 15 spoken words ran past the end of a 6 s shot, 11 fit; title cards letter-perfect in 3 of 3; see [Recipe](#recipe-an-explainer-video-with-a-presenter) |
| Keep video quality through editing | Leave `master` on (default): the Studio exports from the lossless copy; YouTube 1080p at 24 Mbit/s | Export from the copy 42.3 dB instead of 37.7 dB from the MP4; 24 Mbit/s 42.8 dB, 4:2:0 limit 43.9 dB; costs about 32 MB per second at 1080p |
| Sound effects / instrumental music | Stable Audio Open / Stable Audio 3 Medium | Describe the sound for SFX; Stable Audio 3 up to 5 min, one sentence with BPM, no vocals (ACE-Step was removed in 0.5.13) |
| 3D source image | One object, plain background, no floor, no cast shadow; `project_front=True` for lettering | Floor and shadow become a plate under the mesh; painted lettering became a distorted relief |
| Old photo | `restore_image` with `repair_mode="auto"` (default; picks thorough for water stains and crack networks, otherwise gentle), `batch_size=2`, known colors in `notes` | See [Old photos](#old-photos-restore-colorize-sharpen-since-0511): auto chose as expected on 20 of 21 test photos; heavily aged 0.689 thorough vs 0.648 gentle, on real glass plates gentle kept the sharpness; color hints cut the color error by 40 % |

## Run times (measured on an RTX 5060 Ti 16 GB)

| Task | Model | Time |
|---|---|---|
| Image 1024², 28 steps | SDXL Base | ~20 s |
| Image 1024², 8 steps | Qwen-Image-2512 NVFP4 + Lightning | ~17 s, first run ~28 s |
| Image 1024², 50 steps, cfg 4 | Qwen-Image-2512 NVFP4 | ~98 s |
| Image 1328² (Qwen native), 50 steps | Qwen-Image-2512 NVFP4 | ~197 s |
| Image 1024², new prompt (upsampler + 16 steps) | FLUX 3 Klein NVFP4 | ~30 s |
| Image 1024², known prompt, new seed | FLUX 3 Klein NVFP4 | 13–16 s, four images ~37 s |
| Image 1440² / editing with a reference image | FLUX 3 Klein NVFP4 | ~26 s / ~45 s |
| Image 1024², 50 steps, cfg 3.5 | FLUX 3 Klein Base NVFP4 | ~53 s |
| Image 1024² / 1408², 8 steps | Krea 2 Turbo NVFP4 | ~20 s / ~37 s, first image after FLUX 3 ~41 s |
| Image 1024² with one / two style templates | Krea 2 Turbo NVFP4 + style LoRA | ~41–48 s / ~71 s (without ~24 s) |
| Image 1024², 50 steps, cfg 4 | Qwen-Image-2512 INT8 (for RTX 20/30/40) | ~119 s, with loading ~132 s |
| Image 1 MP, 50 / 25 steps (prompt expansion ~11 s extra the first time) | MOSS-Image SFT INT8 | ~51 s / ~28 s |
| Audio 6 s SFX, 50 steps | Stable Audio Open | ~12 s |
| Instrumental 60 s / 20 s / 300 s | Stable Audio 3 Medium (8 steps, CFG 1) | ~9–12 s / ~7 s / ~64 s |
| Video 832×480, 25 frames | Wan 2.1 T2V 1.3B | ~120 s |
| Image 1728 × 2304 (4 MP) | HiDream-O1 Dev fp8 | ~41 s, first run ~87 s |
| Image 832 × 1216, 4 steps | Boogu-Image Turbo NVFP4 | ~10 s, first run ~17 s |
| Edit 832 × 1216 | Boogu-Image Edit NVFP4 | ~147 s |
| Video with sound 1280 × 704, 5 s | LTX-2.5 NVFP4 (graph since 0.5.8) | ~93 s, first run with loading ~122 s; with a start image ~109 s |
| Start and end image 5 s / loop 4 s, 1280 × 704 | LTX-2.5 NVFP4 | ~154 s / ~125 s |
| Video with sound 1920 × 1088, 5 s / multishot 1280 × 704, 8 s | LTX-2.5 NVFP4 | ~251 s / ~170 s |
| Video to a given sound, 20 s, 1024 × 576 | LTX-2.5 NVFP4 | ~302 s |
| Best quality (DFR) 1920 × 1088, 5 s | LTX-2.5 NVFP4 | ~786 s (standard path ~241 s) |
| From a start image, 1920 × 1088: 6 s DFR / 4 s standard (Studio scenes) | LTX-2.5 NVFP4 | ~1519 s / ~249 s |
| From a start image, 1920 × 832 (2.39:1), DFR: 6 s / 5 s / extend by 3 s | LTX-2.5 NVFP4 | ~305–326 s / ~242–245 s / ~146–150 s |
| DFR 1280 × 704, 4 s / with 48 fps | LTX-2.5 NVFP4 | ~118 s / ~294 s |
| Extend a video, 5 s + 4 s, 1920 × 1088 | LTX-2.5 NVFP4 | ~255 s for the new part including joining |
| Video with sound 1280 × 704, 4 s | LTX-2.3 NVFP4 | ~101 s; image to video 448 × 832 ~65 s |
| Video 848 × 480, 49 frames | Mochi 1 preview fp8 | ~351 s with loading |
| Video 768 × 512, 5 s | Kandinsky 5 Lite distilled | ~300 s; 50 steps (T2V, I2V) ~26–27 min |
| Mesh from image | TripoSG | ~180 s cold, ~60 s warm |
| Mesh with the front from the image | TripoSG | ~66 s warm, the projection itself under 1 s |
| Restore a photo 1216 × 1600, thorough + colorize, 1 variant | FLUX 3 Klein NVFP4 | ~115 s |
| Automatic mode: the upsampler checks the kind of damage | Qwen3.5-9B upsampler | ~2.5 s, cached per photo |
| Restore a photo, gentle + colorize, 1 variant | FLUX 3 Klein NVFP4 | ~140 s (putting the damage in costs extra) |
| Remove damage only, thorough, 2 variants | FLUX 3 Klein NVFP4 | ~130–150 s, measured with a game running alongside |
| Sharpen 1200 × 864 → 3840 × 2770 / 1024² → 2048² | SeedVR2 7B NVFP4 | ~18.5 s with loading / ~6 s |

The first job after a start costs an extra ~15–30 s of model loading. For video and 3D, warn the
user up front instead of leaving them waiting.

## Images

### Model choice: the four recommended models

- **Qwen-Image-2512, full version `qwen-image-2512-nvfp4`** (50 steps, cfg 4) — first choice for
  **final assets**, **text in the image** and **structural details**. Crate lettering comes out
  letter-perfect; with the same seed, this version ran a crate's rope handles through drilled
  holes, while Lightning laid them on the wood without any attachment. Apache-2.0, 20B parameters
  in NVFP4. `negative_prompt` works; empty = Qwen's recommended one from the model card (set by
  the server). For more detail, use Qwen's **native sizes** (1328², 1056 × 1584, 1584 × 1056 …):
  measured finer rope twist and wood grain at twice the time (197 instead of 98 s).
  `qwen-image-2512-lightning` (8 steps, cfg 1) only for drafts and composition tests.
- **FLUX 3 Image Klein, `flux3-klein-nvfp4`** (Black Forest Labs, 16 steps, cfg 1) — when working
  with **reference images**: edit an image ("replace the rope handles with iron handles, keep
  everything else unchanged"), keep a character consistent across several images, combine
  subjects from up to ten images. Plus placement by bounding box. A bundled **upsampler** first
  expands every prompt into a full image description — that is what the model is trained on; the
  final description is stored in the asset as `caption`. `negative_prompt` has no effect.
  **Mind the license** (see [Licenses](#licenses--before-using-assets-in-a-game-you-sell)):
  commercial use only below US$5 million revenue, and every image must be reviewed before it is
  published.
  Strong in testing: editing left the source unchanged except for the modified handles, three
  crates landed exactly at their box positions, text came out error-free three times out of
  three, five of five soldiers stood fully inside the frame. Weak: whatever the prompt leaves
  open, the upsampler invents — a greatcoat worn as a cape on the soldiers, lace-up shoes instead
  of marching boots, ropes hanging loosely across the front instead of handle loops. Without a
  style it plans a photo.
  `flux3-klein-base-nvfp4` is the undistilled version (50 steps, cfg 3.5, the negative prompt
  works) — according to BFL mainly intended for fine-tuning; in testing 53 instead of 13 s
  without a visible gain.
- **`flux3-klein-int8`** — the same FLUX 3 in BFL's INT8 version for cards without FP4 units
  (RTX 20/30/40, from 8 GB according to BFL). On an RTX 50 card such as the RTX 5060 Ti, the
  NVFP4 version is the right one. `list_models` marks what suits the detected card with
  `recommended` and explains in `gpu_note` when a format does not run in hardware there. On RTX
  20/30/40 that is INT8, and NVFP4 only on a slow connection (up to 4 GB/s) where only the NVFP4
  version fits into the graphics memory (measured, see Krea 2 below).
  `qwen-image-2512-int8` is the same for Qwen-Image-2512.
- **Krea 2 Turbo, `krea2-turbo-nvfp4`** (Krea.ai, June 2026, 12B parameters, 8 steps, cfg 1) — the
  third choice: **photographic images with little AI look**, fast. Measured with the same prompt and
  seed: about 20 s per 1 MP image (41 s for the first one after FLUX 3), 1408² in 37 s; Qwen-Image-2512
  took 109–160 s, FLUX 3 31–36 s. Natural hands and faces, letter-perfect crate lettering, ropes
  through drilled holes, a standing figure with both boots in the frame. Weak: **name the framing**,
  otherwise it moves what the prompt stresses into view — an old fisherman ("weathered hands") lost
  his head at the top of the frame in three of three images; with "Medium shot from the waist up, his
  whole head and face inside the frame with free space above his head." in none of two. The crate came
  without a lid, which the prompt did not mention. No mask, `negative_prompt` has
  no effect. Text encoder (Qwen3-VL-4B) and VAE are the same files as FLUX 3's and Qwen-Image's, so
  only 7.7 GB remain to download. **Mind the license** (see Licenses): commercial use only below
  US$1 million revenue. `krea2-turbo-int8` for RTX 20/30/40: on a normal connection it was faster
  than NVFP4 even where it did not fit into the graphics memory (13.0 instead of 25.1 s with 8 GB).
  Only on an RTX 4060 on a slow riser (PCIe 3.0 x4) was NVFP4 faster (46 s against 193/82 s);
  `list_models` recommends accordingly.
  **Style template (since 0.5.10):** with ostris' optional style LoRA (0.46 GB) Krea 2 takes one or
  two images in `reference_asset_ids` as a style template: the way of painting, colors and light come
  from the image, the content from the prompt. Measured: a lighthouse took a watercolor or a woodcut
  template clearly, in 41–48 instead of 24 s; light and colors follow the template even against the
  prompt (the storm turned pastel); with two templates 71 s, and the first one wins. Describe only the
  content. If the LoRA is missing, `features.missing.style_reference` says so ("Download extras"
  under "Models").
- **MOSS-Image, `moss-image-sft-int8`** (OpenMOSS, October 2026, 5B parameters, 50 steps, cfg 3) — the
  fourth choice since 0.5.11: **text and layout in the image** (posters, signs, graphics) under
  **Apache-2.0**, so images can be sold without a revenue limit or review obligation. The text encoder
  is Qwen3.5-9B (W4A8; not FLUX 3's upsampler), with the small FLUX.2 VAE (Apache-2.0). Short prompts
  are first expanded by MOSS's own text encoder (system prompt from ComfyUI's template; the result is
  in `caption`, `upsample_prompt=False` switches it off); a JSON with "summary" and "items" as the
  prompt sets the layout and goes to the model without expansion. The negative prompt works. Measured
  with the same prompts and seeds: OpenMOSS's settings (50 steps, cfg 3, euler — the default) 51 s per
  1 MP image, plus ~11 s for the expansion the first time; ComfyUI's template (25 steps, cfg 2.5,
  er_sde) 28 s. Text letter-perfect in every image, the soldier with both boots and the fisherman with
  his head in the frame; crate rope handles through drilled holes in 3 of 3 with 50 steps, in 2 of 3
  with 25. Text to image only (no reference images, no mask, no hires pass); not available on the Mac
  (no MLX version).

What a model can do is machine-readable in `list_models(kind="image", detailed=True)` under
`features`: whether the negative prompt works, reference images, upsampler, recommended sizes,
prompt hint. The web UI's **Generate** page shows and hides its controls accordingly. In detail,
with REST examples and all test findings: [MODELS.md](MODELS.md).

The web UI finds more models under **Models → Search Hugging Face** (REST: `/api/models/search`,
`/api/models/inspect`). Each file is checked before downloading; SDXL and SD 1.5 checkpoints
(Juggernaut, Pony, Illustrious …) can be downloaded. These are multi-GB downloads as well — ask
the user first.

NVFP4 needs PyTorch **cu130** in the ComfyUI venv (`setup_comfyui.ps1` installs it); with cu128
everything is three to five times slower, because ComfyUI then disables its fast NVFP4 kernels.
FLUX 3 needs ComfyUI 0.41 or newer (`install.ps1` pins v0.42.1).
Since 0.5.12 the ComfyUI venv uses PyTorch 2.14.1 + cu130 and torchvision 0.29.1 (what ComfyUI's own package for
0.42.1 ships; before: 2.11.0), without torchaudio, which nothing imports. Measured against 2.11.0 with fixed seeds:
expanded prompts and upsampler captions word for word the same, images 51–57 dB PSNR apart (numeric noise). MOSS-Image
was 30 dB apart: the same poster with the same lettering, but a small island appeared on the horizon, so the same seed
can change small details after such an update. Restoring with sharpening (34 dB) and LTX-2.5 frames (33–35 dB) looked
the same. Run times were the same (one run each), FLUX 3 with a new prompt 30.5 instead of 33.6 s; the full function
test passed 39 of 39.
comfy-kitchen stays at ComfyUI's pin (0.2.39): 0.2.40 broke Qwen3.5 text generation with ComfyUI 0.42.1 (MOSS-Image
"gated_delta_decode_deferred launch rejected", the FLUX 3 upsampler never stopped).
The CUDA 13.2 build of the same PyTorch (cu132) was measured against cu130 with driver 621.01: the same time per step
(FLUX 3 0.510/0.518 s, Qwen-Image 1.780/1.770 s, LTX-2.5 1.26/1.26 s) and bit-identical images, video frames and
texts, so NVAI-open stays on cu130 like ComfyUI's own package. The driver update from 610.62 to 621.01 changed neither
speed nor results either.

### Prompts for Qwen, FLUX 3 and Krea 2

All three read the prompt with a language model (Qwen2.5-VL-7B, and Qwen3-VL-4B for FLUX 3 and
Krea 2), not with CLIP. The old CLIP rules further down (77 tokens, `(word:1.3)`) do **not** apply to them.

- **Full English sentences.** First medium and style, then the subject with material, color and
  condition, then lighting and background. Long prompts are no problem.
- **State the construction explicitly**, otherwise it gets invented: *"rope handles pass through
  drilled holes in the side boards"*, *"the lid is held by two iron hinges at the back"*.
- **Text in quotation marks**, verbatim, with position and type: *"black stenciled letters on
  the front read \"MUNITION 7,92\""*.
- **No weighting brackets** — for the language-model encoder they are noise, and the FLUX 3
  upsampler carries them into its description.
- **FLUX 3:** short and complete is enough — **style first** (otherwise it becomes a photo),
  then subject, count, arrangement, construction, text. The upsampler writes 100–350 words from
  it and fills every gap by itself: specify clothing, shoes and fastenings explicitly if they
  have to be right. If the image is wrong, read `caption` first: if the error was already there,
  extend the prompt instead of rerolling. Use `upsample_prompt=False` only when the prompt itself
  is already a full description in this style — without the upsampler, the test crate came out
  plainer.
- **FLUX 3 with reference images** (`reference_asset_ids`, up to 10): say "the first image",
  "the second image" in the prompt. Editing = say what changes and what stays the same.
- **FLUX 3 boxes:** append a table to the end of the prompt:
  `[{"id": "crate_1", "bbox": [top, left, bottom, right], "desc": "…"}]` on a 0–1000 grid. Do
  **not** cite the ids in the text as `<crate_1>` — the upsampler does that, and the boxes stay
  fixed. If the text cites all ids, it counts as a finished description and goes to the model
  without the upsampler (that is how BFL's reference code does it). The boxes steer position and
  size but are not a hard mask.
- **Krea 2:** as for Qwen, and **name the framing** ("medium shot from the waist up, his whole head
  inside the frame", "full body, both boots inside the frame"). It has no upsampler of its own:
  expand a few words with `expand_prompt` first.

### Decide first: scene or isolated object?

The two cases need different sizes and different prompts.

**Narrative scene** (several objects, an action, a mood). Rules:

- **Never count — arrange.** "exactly one truck" has no effect — the number of objects comes from
  the initial noise, not from the number in the text. Instead: *"the front tanker truck rolls
  through the barrier. Behind it a line of separate tanker trucks waits nose to tail, each with
  its own dark cab."* Without "separate"/"each with its own", similar objects merge into a single
  impossible contraption.
- **Style and lighting at the start**, in sentences of their own. Say positively what it *is*:
  *"A painted illustration in oil on canvas with visible brush strokes."* instead of "not a
  photo".
- **One sentence per image element.** Qwen, FLUX 3, Chroma and LongCat cope with long prompts;
  a single colon-laden sentence with five statements, on the other hand, gets squashed together.
  With FLUX 3, a box table can additionally pin down the arrangement.
- **State the time of day explicitly**, otherwise you end up at dusk.
- With ~8 simultaneous conditions, no model hits everything on the first try — even the best stay
  below 31 %. Generate several candidates and pick one.

**Isolated object or figure** → continue with the size rules below.

### People in the image — two measured traps

**Figures need pixels.** At 1024×1024, a person in the middle ground is about 80 px tall — that
produces blobs instead of faces, and feet go missing entirely. Measured with the same prompt and
seed, shapeless figures turned into clean people as soon as three things came together:
`width=1216, height=832`, `steps=26` and **`hires=True`**.

Remember: **as soon as people are recognizable in the image, use `hires=True`.** It is the most
effective single switch against missing feet and broken faces. `steps=16` is only enough for
dark, atmospheric scenes without faces. (Measured with Chroma. FLUX 3 has no second pass —
choose a larger size directly there; the model works natively up to 4K.)

**Style bans in the negative prompt flatten the look.** Terms like `loose brushwork,
impressionistic, sketch, visible pencil lines, smudged, unfinished` forbid any visible paint
texture — what remains is smooth cel shading. Equally contradictory: `photographic detail` in the
positive and `photorealistic` in the negative prompt. Keep the negative prompt to ~10 terms.

**State people's origin explicitly.** Without it, the figures' appearance varies; in testing,
the same prompt produced European faces one time and South Asian faces another. With it, every
variant was unambiguous. The effective pattern is **region + facial features**:

```
Two Central European dock workers with pale northern European features, ...
```

"German soldier" alone hardly steers appearance; "with pale northern European features" does.
This applies in both directions — for a Pacific setting, the matching description belongs in the
prompt just as explicitly.

### The size matters more than the prompt

**A standing figure belongs in portrait format.** In a square, it is more likely to lose legs or
feet, and it simply gets fewer pixels for the part that matters. The image format should match
the subject's silhouette — portrait for standing figures, landscape for vehicles.

| Size | Use for |
|---|---|
| **832 × 1216** | standing figures, soldiers, characters |
| 896 × 1152 | figures, less extreme portrait format |
| **1024 × 1024** | objects, icons, symbols |
| **1216 × 832** | vehicles, buildings in side view |
| 1344 × 768 | wide scenes, panoramas |
| 512 × 512 | sprites, tiles |

These are all around 1 megapixel and suit every model. Beyond that, it depends on the model:

- **Qwen** is trained at ~1.76 MP: 1328 × 1328, 1056 × 1584 (figures), 1584 × 1056 (vehicles),
  1104 × 1472, 1472 × 1104, 928 × 1664, 1664 × 928. Measured: more detail at twice the time.
- **FLUX 3** works natively up to 4K; the API allows up to 2048 × 2048. Sides must be multiples
  of 16.
- Older models (Chroma, SDXL) become noticeably incoherent above 1 MP.

`features.sizes` in `list_models` lists the sizes for each model.

### Prompt patterns

For **Qwen and FLUX 3** — full sentences, no brackets:

```
Figure:   "Studio photograph of a single WW2 German infantry soldier in full body, standing
           at attention in strict side view, both boots fully inside the frame. Weathered
           field grey uniform, steel helmet, rifle slung over the shoulder. Plain light grey
           background, even soft studio light."
Object:   "Studio product photograph of a weathered wooden ammunition crate. Black stenciled
           letters on the front read \"MUNITION 7,92\". Rope handles pass through drilled
           holes in the side boards. Plain light grey background, soft even light."
FLUX 3,   prompt="Replace the rope handles with forged iron handles bolted to the side
editing:         boards; keep everything else unchanged", reference_asset_ids=[crate]
```

For **CLIP models** (SDXL, Pony, Illustrious, FLUX.1, Chroma with T5):

```
Figure:   "a WW2 German infantry soldier, (full body:1.2), standing at attention,
           (feet inside the frame:1.2), strict side view, weathered field grey
           uniform, plain light grey background, even studio lighting"
negative: "(cropped:1.3), cut off, multiple figures, text, watermark, blurry"
```

- **Weighting only works there**: `(term:1.3)` emphasizes, `(term:0.7)` dampens. Apply it to
  composition anchors, not to style.
- **Stay under ~55 words** (CLIP only): the global conditioning vector is built from the first
  77 tokens.

For all models:

- **Name exactly one view.** "side view" and "three-quarter" together produce exactly the
  distortions you want to avoid.
- **Common type designations** ("Panzer IV", "Sherman M4", "Sd.Kfz. 251") call up a learned
  shape instead of a free interpolation.
- **Plan hands out of the picture** instead of describing them: a medium shot instead of a
  close-up, hands on the rifle or gloved. "five fingers" in the prompt doesn't help.
- **`batch_size=4`** instead of four calls: one model load instead of four. Anatomy errors are a
  failure rate — generating several candidates and taking the best is the most effective method.

### The quality switches

| Parameter | When |
|---|---|
| Qwen's native sizes | final assets with Qwen: 1328², 1056 × 1584, etc. More detail, twice the time |
| `hires=True` | anything with hands, faces, fine technical detail (not with FLUX 3). Recomputes details in a second pass. Costs ~50 % more time |
| `reference_asset_ids` | FLUX 3: change an almost-right image in a targeted way instead of rerolling |
| `image_asset_id` + `denoise` | other models: refine an almost-right image. 0.3 gentle, 0.5 noticeable. With FLUX 3 the image becomes the first reference |
| `image_asset_id` + `mask_asset_id` + `denoise=1.0` | regenerate only one area (inpainting): white in the mask is recomputed, black is kept, gray levels blend smoothly. Upload the mask via `POST /api/upload`. Measured with full Qwen: lettering cleanly replaced, 0.6 out of 255 deviation outside the mask. In testing, Lightning (cfg 1) mostly just continued the surroundings. Since 0.5.6 FLUX 3 fills too (`features.mask == "reference"`): the server greys the area, lets FLUX 3 paint it and puts back only the area, aligned. Measured: crates removed with the cobblestones running on, a seagull added. To change something already there (lettering on a sign), edit with a reference image instead |
| `steps=16` | with Chroma instead of the default 26 — measured 58 instead of 90 s at the same quality |
| `batch_size=4` | whenever you want to choose. One model load instead of four |

`slg` only has an effect with SD 3.5 models, and `controlnet_*` only with SD 3.5 Large and the SD
3.5 ControlNets from the catalog. No ControlNets are integrated for Qwen, FLUX 3, Chroma or
LongCat.

### Historical vehicles — honest expectations

With tanks, aircraft and ships, no prompt helps against wrong geometry: **no model knows the
silhouette of a Panzer IV.** Tested — two seeds with an identical prompt produced two completely
different invented vehicles, both cleanly drawn, both historically wrong.

It follows that **more seeds don't help here.** Unlike with figures, the model is not rolling
between good and bad but between different fantasy vehicles. Tell the user that instead of
rerolling ten times.

When historical accuracy matters, you need a template (blueprint, three-view drawing, blockout)
and a matching ControlNet. None is currently integrated for Qwen, FLUX 3, Chroma or LongCat. FLUX
3 does take a photo or drawing as a reference image, but according to BFL references fix the
content, not the shape — they don't replace a ControlNet.

### Other models in the catalog

- **Chroma1-HD (fp8)** — best painterly style, best atmosphere, `negative_prompt` works
  (cfg 4.0), Apache-2.0, unfiltered. Run it with `steps=16`
- **LongCat-Image** — when an **action** must be visible; it hits actions most reliably, but
  easily turns photorealistic. `negative_prompt` works
- **FLUX.1 schnell** — fast for previews, but `negative_prompt` has **no effect** (cfg 1.0):
  phrase exclusions positively there
- **Chroma1-HD (bf16)** — don't use it; it doesn't fit into 16 GB and is slower with the same
  result
- **SDXL Base / Juggernaut** — largest LoRA ecosystem, fast and frugal
- **Illustrious / NoobAI** — stylized, 2D; they need **Danbooru tags**, not sentences
- **Pony V6 XL** — characters, needs `score_9, score_8_up, …` in the prompt

### What doesn't help

- **"bad anatomy", "extra fingers", "mutated hands"** in the negative prompt — SD 1.5 folklore
  with no counterpart in these models' training. It only dilutes the rest of the negative
  prompt.
- **Cranking up CFG** — burnt colors, not better shapes. Keep the model default
  (`features.cfg`).
- **`karras` or `exponential` as scheduler** — they squeeze the shape-forming phase into a few
  giant steps and make deformations worse.
- **More steps than the model default** — buys detail, not structure. Whether a figure has two
  legs is decided after a third of the steps. (A distilled version like Qwen Lightning is a
  different matter: compared with the original, it really does lose construction.)

## Old photos: restore, colorize, sharpen (since 0.5.11)

`restore_image(image_path=...)` (or `image_asset_id`) runs up to three steps in this order, each one
switchable. The REST route is `POST /api/image/restore`, the web UI has the **Restore** tab, the
PhotoCraft add-on a **Restore** mode.

**1. `repair` — remove damage.** FLUX 3 Klein gets the photo as a reference with a fixed restore
instruction (your `notes` are appended) and redraws it at 2 MP, capped at the photo's size. NVAI-open
then aligns the result with the photo (measured correlation 0.88–0.99), so it stays congruent.

- **`repair_mode="thorough"`:** the whole picture comes from FLUX. Cracks, crack networks, fine
  scratches, water stains and fading go. Film grain partly stays, because FLUX reproduces it.
- **`repair_mode="gentle"`:** only the damage NVAI-open detects (dust, spots, scratches, stripes,
  tears, light leaks, writing on the print) is put into the photo at full resolution, plus FLUX's
  contrast and fading correction. Sharpness, faces and fine detail stay exactly the photo's.
- **Rule, by the kind of damage rather than its amount:** overall aging (water stains, crack networks,
  grain, fading) → thorough. Separate damage on an otherwise good photo (dust, scratches, stripes,
  tears, light leaks, writing) → gentle.
- **`repair_mode="auto"` (default) applies that rule.** Before the FLUX run, FLUX 3's prompt upsampler
  (Qwen3.5-9B, it sees the photo at 1 MP) answers one question, greedy decoding, about 2.5 s: *"Are there
  water stains, rings left by water, or crack networks (craquelure) in this photograph? Answer yes or
  no."* (system prompt: *"You are an expert in restoring old photographs. Answer with one word: yes or
  no."*). An answer starting with "no" → gentle, anything else → thorough. The FLUX run is the same for
  both modes, so auto costs nothing else. `meta.repair.auto` holds the choice, `meta.repair.auto_answer`
  the answer, and the history label says "restored thoroughly" or "restored gently". On 21 test photos
  it picked the expected mode 20 times: all 8 heavily aged ones yes, all 8 lightly aged ones no, the
  ferrotype yes, the baseball player, Iwo Jima and the torn print no; only the pigeons in Paris (a
  sharp glass plate with dust) got yes, where gentle would have been sharper. Live on the installed
  version: the heavily aged portrait "Yes" → thorough, the baseball player "No. The photograph contains
  scattered scratches, …" → gentle.
- **The wording of that question matters.** "Does this photograph show water stains, water rings or a
  network of fine cracks across the picture?" got 18 of 21 right, "Is this photograph damaged by water
  stains or by a network of fine cracks?" only 14 (it said yes to clean glass plates). Asking for one
  of two words, OVERALL or SEPARATE, got OVERALL for all 16 photos asked, and SEPARATE first still
  missed three; a 0–10 degradation score gave 7–9 to almost everything.
- **Measured on test photos with a known undamaged original** (8 photos generated with Krea 2 and aged
  synthetically, both modes from the same FLUX run; structural similarity of the brightness at a
  quarter of the size, 1 = identical): heavily aged, the damaged photo scored 0.601, gentle 0.648,
  thorough 0.689 (thorough ahead on all four photos); lightly aged 0.921, 0.932 and 0.911: there gentle
  was closer, and thorough drew the faces in a group photo differently and ended up below the
  untouched photo.
- **Seen on five real old photos (public domain):** gentle kept the sharpness and the faces on the
  glass plates (a 1911 baseball player with emulsion damage, 1925 pigeons in Paris with dust spots), on
  Iwo Jima 1945 with a light leak and on a 1945 print with a torn-off corner; thorough came out softer
  or invented texture there. On an 1860 ferrotype speckled all over, thorough was cleaner.
- **How this came about.** The first build defaulted to gentle. A user restored and colorized a
  heavily aged portrait and found it "only looks colorized, the quality is even worse than before": the
  water-stain ring, the grain and the faded look were all still there, now in color. Thorough removed
  the ring and the fading and even brought back the moustache that the fading had washed out (the
  undamaged original has it); some grain stayed. When auto cannot ask (no upsampler) or the answer is
  unclear, it takes thorough, whose worst case (softer, a slightly changed face) is milder than
  gentle's (the damage stays).
- **What did not work as an automatic switch** (all measured on the same photos): the damage share that
  gentle detects (light 0.5–0.9 %, heavy 5.2–10.4 %, but the baseball player 3.1–4.6 % and Iwo Jima
  8.9–9.1 %, gentle better on both: it measures the amount, not the kind); film grain; how much fine
  detail FLUX keeps and how well it correlates with the photo (FLUX reproduces grain in place); a
  second detection pass on the gentle result (water stains and crack networks are below its
  thresholds).
- **Faces vary with the seed.** In one of two thorough variants a 1911 portrait got a wider face and
  a different smile. Keep `batch_size=2` and compare the faces at full resolution; if none fits,
  try gentle.
- **Working size 2 MP:** at 1 MP a soldier in a group photo (Iwo Jima, 1945) got a stranger's face.
  2 MP costs about twice the time.
- The instruction keeps "the original tones": with "black-and-white tones" sepia turned grey. To keep
  a sepia tone, don't write "black and white" into `notes` either.
- Small marks that FLUX leaves out disappear in both modes (a hyphen and a comma in a caption):
  check lettering.

**2. `colorize`.** FLUX 3 colorizes at 1 MP, but only the color (Lab a/b) is taken over and laid onto
the brightness of the photo (or of the repaired picture) at full resolution with a guided filter.
FLUX alone smoothed the skin and changed a smile; with the transfer the face stays. Known colors in
`notes`, in English ("his suit is dark brown, her dress is dark red with white dots"), cut the
measured color error from ΔE 17.4–17.7 to 10.2–10.6. Without hints the colors are plausible guesses:
the brown suit of a test portrait came out blue. Color can bleed across edges of equal brightness (a
light cap brim in front of a light sky).

**3. `sharpen` with `scale` 1–4.** SeedVR2 7B (ByteDance, Apache-2.0, `list_models(kind="upscale")`)
sharpens and enlarges to photo size × `scale`, at most 16 MP: 1024² → 2048² in ~6 s, 1200 × 864 →
3840 × 2770 in 18.5 s with loading. Crisp, with slightly more contrast; at strong enlargement it
invents fine detail (feathers on pigeons). Trap for your own graphs: SeedVR2 reads a batch of images
as one video, so NVAI-open runs the variants one by one.

**Not built in, with reasons:** DDColor (Apache-2.0, 0.2 s, but it needs extra ComfyUI architectures
and the generic upscale node tiles at 512 px, so every tile gets its own colors; in the ColorFLUX paper
(CVPR 2026) FLUX Kontext came out ahead of DDColor); CodeFormer (not commercial) and GFPGAN need face
detection. FireRed Image Edit 1.1 (Apache-2.0) and Mage-Flow-Edit (MIT) can restore according to their
makers; untested, but a possible way around the FLUX license.

**License:** what FLUX 3 computes (repair, colorize) falls under the FLUX Kommunity License; review
every image before publishing. SeedVR2 output is free (Apache-2.0).

## Audio

Three different models — adapt the prompt style to the model:

**Stable Audio Open** → sound effects and ambience. Describe the **sound**, not the music:

```
"heavy metal sword clash, single impact, bright metallic ring, dry studio recording"
"footsteps on gravel, close mic, no music"
"rain on canvas tent, distant thunder, loop"
```

Up to 47 s. For loops, generate generously and let the user trim.

**ACE-Step (v1 and 1.5) was removed in 0.5.13**: its results were consistently poor in practice. Our graph matched ComfyUI's
template `audio_ace_step_1_5_checkpoint`; ComfyUI 0.42.1 also ships ACE-Step 1.5 XL templates (about 20 GB with the 4B
planning model), untested here. There is no model for songs with vocals now; `music` as an expand target stays for older
clients and means Stable Audio 3, and `lyrics`, `bpm`, `time_signature` and `key_scale` are still accepted but have no
effect.

**Stable Audio 3 Medium** (since 0.5.7) → instrumental music up to 5 minutes, no vocals (a choir
only without words). Write the prompt as **one sentence**: genre with the main instruments,
layers and percussion, the mood, then "BPM: 100.". NVAI-open appends "Length: N seconds" to match
`seconds`. `expand_prompt` with `target="music_sa3"` writes exactly this form.

```
prompt: "A dark orchestral war theme with low brass, taiko drums and a wordless male choir,
         slowly building tension over a steady march rhythm. BPM: 90."
```

Measured: 300 s in 64 s, but the 16 GB card was almost full (60 s: 9.7 GB).

**Levels:** since 0.5.7 every audio output goes through NVAI-open's own limiter before it is saved
(ceiling −1 dBFS). Measured with the limiter: Stable Audio 3 −12 to −15 LUFS, true peak −0.5 to
−0.8 dBTP (what is left above −1 dB is MP3 overshoot).
Normalize before putting a track into a video (ffmpeg `loudnorm`, −14 LUFS).

`seconds` controls the length (up to 300). Short SFX: 3–8 s. Music: 30–120 s.

## Video

### First choice: LTX-2.5 (fully built out since 0.5.8, the recommended video model)

`ltx25-distilled-nvfp4` (RTX 50) or `ltx25-distilled-int8` (RTX 20/30/40, not measured yet): picture
and sound in one pass, MP4. Lightricks, LTX-2 Community License (free below US$10 million revenue).
Write the prompt as Lightricks recommends: one paragraph in the present tense, 4 to 8 sentences in the
order shot → setting and light → the action with verbs → people (physical cues instead of emotion
words) → camera movement → sound; spoken lines in quotation marks; write pacing and pauses out.
Use `fps=24`, sizes from `features.sizes` (multiples of 64; 1280 × 704 is 720p), frames 8n+1
(97 = 4 s, 121 = 5 s, 481 = 20 s).

`generate_video` options for LTX-2.5:
- `image_asset_id`: start image (image to video).
- `end_image_asset_id`: last frame; with a start image the clip is a transition. `loop=True` uses the
  start image as the end image too, for a seamless loop.
- `quality="dfr"`: Diffusion Fidelity Rendering — detail keyframes plus a detail IC-LoRA, sharper and
  slower; `temporal_upscale=True` doubles the frame rate (48 fps). Not together with an end image.
- `auto_duration=True`: the model picks the length (1–20 s) from the described action.
- `audio_asset_id`: a given sound (e.g. music from `generate_audio`); the picture follows it, the
  original sound ends up in the MP4, the clip takes its length (at most 20 s).
- `motion_speed` below 1: slow motion (0.5 = 2×, 0.2 = 5×, 0.1 = 10×), reliable with the Slow Motion
  Control LoRA and a start image.
- Several shots in one clip: no parameter — write every cut out in prose ("A hard cut transitions to a
  close-up of …"), 2–4 shots; `expand_prompt(target="video_multishot")` writes that form.
- `extend_asset_id` (since 0.5.10): continue an existing video. Its last frame becomes the start image,
  size and frame rate come from it, and the new part is appended with its sound as a new asset
  (`meta.extended_from`). The prompt describes what happens next, `frames` the length of the new part.
  Not together with a start image, a loop or a given sound. Measured at 1080p: 5 s + 4 s → 9.04 s in
  255 s, no visible seam.

DFR, automatic length and 48 fps need small optional files; the detail IC-LoRA for DFR sits in its own
gated repo. If something is missing, `features.missing` names the Hugging Face page.

Measured on an RTX 5060 Ti (24 fps, with sound, graphics memory almost full): see the table above.
A loop's first and last frame differ by 3.6/255 on average (12–44 without a loop), but only with a
still camera: with "the camera pushes in" the last frames of a loop fell apart. Automatic length
gave 3 s for a door that opens slowly; 20 s of a given sound became a 19.7 s clip. Sounds described
as quiet ("crackles softly") come out at −41 to −52 LUFS, speech and a forge at −14 to −18 LUFS:
name loud sources explicitly. Generated sound goes through the audio limiter (−2.5 dB, because AAC
overshoots dense sound by up to 1.9 dB) since 0.5.8; a
given sound stays unchanged.

**DFR** (accept the license of the detail IC-LoRA on Hugging Face first): ComfyUI's template
video_ltx2_5_dfr_i2v.json inserts the start image at a quarter of its size in every stage, and
LTXVImgToVideoInplace scales a smaller image up to the latent size and fixes it as the first frame. At
1080p the whole video turned soft (same seed: edge sharpness of the face in the first frame 14 instead
of 554 on the standard path). Since 0.5.9 NVAI-open uses the full image in stages 2 and 3. Measured
afterwards (edge sharpness of the face at 0 / 0.5 / 2 / 4.5 s): DFR 445 / 395 / 625 / 523, standard
554 / 548 / 211 / 411 — the detail stays over the whole clip, at 786 instead of 241 s (5 s, 1080p).
The web interface makes DFR the default once the IC-LoRA is installed; an end image or a loop switches
back to standard. `temporal_upscale=True` (48 fps) kept the same sharpness, even and odd frames alike,
at 294 instead of 118 s (4 s, 1280 × 704).

**Cinemagraph LoRA:** only works with a start image and `loop=True` (the web interface switches the
loop on when you activate the LoRA). Measured with a king in front of flickering torches (4 s): with
the loop 6 % of the picture moved and the face stood still, a loop without the LoRA 28 %, without a
loop 82–84 % (also at strength 1.2), because the camera pushed in.

**Slow Motion LoRA:** with Lightricks' settings (1920 × 1088, 121 frames, `motion_speed=0.2`, strength
1.0) the spray of a wave against rocks fell over the whole 5 s instead of about 1.5 s at speed 1.0, with
sharp droplets: real slow motion. Without the LoRA the spray stood almost still as a milky veil. At
1280 × 704 and 0.25 the effect was weaker. 5 s at 1080p took 232–275 s.

**Recommended LoRAs** (`list_models(kind="lora")`, `features.recommended_for` contains `ltx25`,
`features.strength` is the suggested strength): Cinemagraph and Slow Motion Control (official, gated),
Transition (Apache-2.0), Crisp Enhance, Fantasy Anime, Fantasy Painterly, Claymation, Paper Cut-Out,
Sci-fi Cyberpunk (no license stated), Audio Reactive. Lightricks' IC-LoRAs (Restore, Relight,
Day-To-Night, Alpha-Gen …) need a source video; NVAI-open has no video to video yet. Tested on
LTX-2.5: Fantasy Anime and Fantasy Painterly show clearly; Paper Cut-Out only at strength 1.5 (now its
`features.strength`); Claymation is only hinted at; Transition hardly changed a day-to-night
transition; with Audio Reactive the brightness followed the music a little more closely, but LTX-2.5
already pulses to a given sound without it.

### LTX-2.5: sharpness, bitrate and prompt traps (measured at 1920 × 1088)

- **Prefer the higher quality and say so:** final videos at 1920 × 1088 (about 2.7 times as long as
  1280 × 704), start images in that size too, and `quality="dfr"` when `features.dfr` is true (about
  three times as long).
- **Bitrate:** MP4s are saved with CRF 12 instead of ComfyUI's 18 (`crf` per request). With the same
  seed 16.0 instead of 7.3 Mbit/s, 10 instead of 4.5 MB for 5 s. Fine detail barely changes: the
  softness comes from the model, not from the encoder.
- **Face after a zoom out: give an end image.** Without one, the face in the last frame of a 7-second
  zoom out (about 80 px wide) came out soft and distorted. An end image made with FLUX 3 (same
  references) keeps it: the last frame matches the end image, 648 instead of 509 s. Asked for a
  "wider shot", FLUX 3 kept the framing; a wider end image comes from outpainting
  (`outpaint=[320, 184, 320, 184]` turns 1920 × 1088 into 2560 × 1456, the person then ends at 75 %).
- **End image or standard path:** with an end image the picture stood almost still for the first
  second and faces turned soft during big moves, but the ending matched the end image sharply. The
  standard path moves at once and keeps faces sharper during the motion. Use the end image when the
  face has to be right at the end (zoom, ending at rest).
- **Prompt traps** (a speaking person in front of a crowd, two seeds each): "shouts" gives grimaces
  ("says firmly in a rough, deep voice" is calmer). A gesture that "may rise out of the top of the
  frame" makes the camera follow it. "The camera holds a medium close-up" became a push-in to an
  extreme close-up; "Static camera, a locked-off medium shot; the framing stays exactly as in the first
  frame." held the framing. "Proud, calm expression" became a grin; "stern, determined expression and
  does not smile" did not. A raised fist filling the frame lost a finger; keep it small next to the
  head.
- **Start image:** thin props that cross people (rifles, flag poles) morph into each other in the
  video. Keep them apart in the start image (FLUX 3 edit in the video size) and do not move them all
  at once in the prompt.
- **Big body moves:** a person landing after a jump (8 s) worked as a motion, but the face was
  unrecognizable afterwards. Check start images of full-size people at 100 % for their eyes before
  rendering.

### Person from a photo (since 0.5.8)

Turn a portrait into a video: the face from the photo in a role, saying a line. Two steps (web
interface: Video tab → "Person from a photo"; by hand over MCP/REST the same way):
1. **Start image with FLUX 3:** the photo as a reference (`reference_asset_ids=[photo]`), prompt
   "Cinematic film still. The person from the first image, with exactly the same face, eyes, nose,
   mouth and hair color: <role>. Medium shot from the waist up, the face clearly visible, free space
   above the head." in the video size with `batch_size=4` (1280 × 704: 95–98 s). Crop the photo to head
   and shoulders and name the clothing explicitly. FLUX makes faces a little slimmer and younger, so
   compare the four variants with the photo at full resolution.
2. **Video with LTX-2.5** from the chosen image: motion only, the spoken line in quotation marks with
   the voice ("says in a rough, deep, gravelly voice: "…""), then the sounds. 5 s at 1280 × 704 in 82–128 s.

Measured with two portraits: "pulls back a little" became a wide shot, "holds a steady medium shot" kept
the framing longer. If the person turns away, LTX redraws the face afterwards and it looks less alike;
"keeps facing the camera" keeps it in view, but on a push-in LTX still smooths it toward an average
face. The voice is generated by LTX, never the person's real one.

### Other video models

```
prompt: "a burning torch mounted on a dark stone wall, flame flickering,
         warm light, slow subtle camera push in"
```

- **Describe motion explicitly** — without a motion cue, little happens.
- Leave `negative_prompt` empty; the default is already sensible.
- **832×480 is the cheapest Wan default.** 720p costs many times as much.
- `frames` is rounded to **4n+1** (Wan) or 8n+1 (LTX). 49 frames at 16 fps ≈ 3 s.
- Output is **WEBM/VP9** (Wan, Mochi; LTX and Kandinsky give MP4) — plays in the browser; convert it
  for Unity if needed.

Without LTX-2.5: **Wan 2.1 T2V 1.3B** for fast iteration, **Wan 2.2 TI2V 5B** for quality (13 GB
VRAM — don't keep anything else loaded).

### Image to video

Bring an existing image to life instead of generating one from nothing — pass `image_asset_id`
to `generate_video`:

```
1. generate_image("a woman in a red dress standing on a beach at sunset, cinematic")
2. list_assets(kind="image", limit=1)      → asset_id
3. generate_video(prompt="gentle wind moves her dress and hair, slow camera push in",
                  image_asset_id=asset_id, model_id="wan22-i2v-a14b",
                  width=832, height=480, frames=49)
```

Rules that make the difference:

- **Describe only the motion in the prompt.** The image is already there; retelling it costs
  prompt budget and gains nothing.
- **Match the start image's aspect ratio.** A different `width`/`height` is hard-cropped or
  scaled.
- Without `image_asset_id`, an I2V model fails with a clear message — it doesn't guess.

| Model | Use for |
|---|---|
| **Wan 2.2 I2V A14B** | First choice. Best motion, Apache-2.0, 720p possible |
| **Wan 2.1 I2V 480p 14B** | 10 GB smaller, no expert switch — otherwise weaker |
| **Wan 2.2 TI2V 5B** | Does both; I2V with a start image, T2V without |

**Wan 2.2 I2V A14B loads two experts one after the other** (high-noise for motion, low-noise for
details). That costs a model switch in the middle of the run — expect considerably more time than
with text-to-video, and tell the user beforehand.

## Studio: whole videos from scenes (since 0.5.13)

A Studio project has two timelines. The **composition** holds scenes (prompt, model, length) on four
lanes, `video` (video clips or still images), `voice`, `music` and `sfx`, plus markers that say what goes
where. The **edit** holds the real clips on the tracks V1, V2 (above V1), A1 and A2, with in and out
points, gain and dissolves. The web UI (tab "Studio") uses the same commands as the MCP tools, so the
user sees every change live and can undo it. User guide with screenshots: [STUDIO.md](STUDIO.md).

| Tool | Purpose |
|---|---|
| `studio_projects` | Projects, newest first |
| `studio_create(name, width, height, fps)` | New project, returned in compact form (times in seconds) |
| `studio_get(project_id)` | Scenes with status (`empty`, `waiting`, `running`, `done`, `error`) and take, markers, clips, length. Finished jobs are already entered as takes |
| `studio_command(project_id, command, params)` | One command; the tool's description lists them all: `scene.add/update/delete/take`, `marker.add/update/delete`, `edit.conform`, `clip.add/move/trim/razor/delete/update`, `project.update` |
| `studio_generate(project_id, scene_ids=None, wait=True)` | Generates every scene without a take, or the given ones; with `wait` it blocks until all are finished, chained ones included, for at most an hour. For long runs (several DFR scenes) use `wait=False` and poll `studio_get` |
| `studio_export(project_id, preset)` | Renders the edit, returns the MP4 path |

Workflow:

1. `studio_create`, then one `scene.add` per shot. Write each video prompt like for `generate_video`
   (one present-tense paragraph: shot, light, action, camera, sound). Add `marker.add` with
   `kind="chain"` where two shots must join seamlessly and `kind="transition"` for dissolves.
2. `studio_generate(wait=True)`, then look at the takes and regenerate the scenes that missed with
   `studio_generate(scene_ids=[...])`.
3. `edit.conform`, cuts with `clip.razor`, `clip.trim`, `clip.delete`, then `studio_export`.
4. Markers of kind `ai` that are not done are tasks the user left for you: carry them out, then
   `marker.update` with `done=true`.

Times are seconds with the suffix `_s` (`start_s`, `duration_s`, `at_s`, `in_s`, `to_s`) or ticks
(254 016 000 000 per second, as in FilmCraft, which divides every frame and sample rate).

How a scene becomes a job:

- **Video:** LTX-2.5 with frames = 8n+1 from the length at 24 fps, 1280 × 704 (projects below 1900 px)
  or 1920 × 1088; other video models 832 × 480 at 16 fps. `params` in the scene pass on seed, steps,
  LoRAs, `quality`, `motion_speed` and an end image.
- **Still image:** about 1 MP in the project's aspect ratio (1360 × 768 in a 1280 × 720 project).
- **Music and sound:** the scene's length (up to 300 s), lyrics from the scene.
- **Voice:** no text-to-speech yet; the job fails with a hint. Add a recorded audio file as a take
  (`scene.take` with `asset_id`).
- **Chain:** a video scene with `chain_from`, or starting at a `chain` marker (± 0.5 s), gets the last
  frame of the earlier scene as its start image. If that scene is generated in the same run, the
  chained one has the status `waiting` and is submitted as soon as its source is done; if the source
  fails, the chained scene gets an error instead of waiting forever.
- **Order in the GPU queue:** sound first, then still images, then videos grouped by model, chained
  scenes last. A chained clip then runs right after its source without LTX-2.5 being unloaded for an
  image or audio model in between.

Export presets: `youtube-1080p` (H.264, 24 Mbit/s), `youtube-2160p` (H.265, 40 Mbit/s),
`shorts-1080x1920`, `av1-1080p`, `project` (H.264 in the project's size), `master` (FFV1 in MKV, sound as
float PCM, pixel-exact) and `prores` (ProRes 4444 in MOV, 24-bit sound, for editing software). The
encoder is chosen by trying one frame: NVENC, AMF, Quick Sync, then software. The sound of all clips is
mixed, set to −14 LUFS (BS.1770) and limited at −2.5 dBFS (−1 dBFS for PCM). The export runs in its own
queue next to generation. Browsers cannot play FFV1 or ProRes, so those exports get an H.264 preview
written in the same pass (`meta.preview`); uploaded MKV, MOV or AVI files get one in the background.

**HQ 1080p is the default** (the user's focus): new projects are 1920 × 1080, video scenes run LTX-2.5 at
1920 × 1088 with "Best quality (DFR)" when the detail IC-LoRA is installed (project setting
`video_quality`, `project.update` with `dfr` or `standard`; 5 s at 1080p: 786 instead of 241 s; say so
before generating many scenes). The export crops the 8 extra rows instead of rescaling: a clip whose
aspect ratio is within 5 % of the project's fills the frame, others are letterboxed.

**Every generated video also has a lossless copy** (see [Lossless copy](#lossless-copy-of-every-video-since-0513)),
and the Studio reads from it for the export and for chain start images. Measured: a YouTube 1080p export
from the MP4 reached 37.7 dB PSNR against the original, from the lossless copy 42.3 dB at 12 Mbit/s and
42.8 dB at 24 Mbit/s; 4:2:0 color itself caps at 43.9 dB, so more bitrate buys almost nothing.

The media bin in the web UI lists everything from the History; deleting an asset there or with
`delete_asset` drops it from the scenes' takes, clips whose file is gone are marked `missing` (the export
then refuses with a message). Assets that lie as a clip in the open edit cannot be deleted from the bin.

Measured on an RTX 5060 Ti 16 GB, everything through the MCP tools: four scenes (two LTX-2.5 clips of
3 s at 1280 × 704, the second one chained, a Krea 2 still image, 9 s of music with Stable Audio 3) in
270 s together, in this order: the music 62 s including the backend start, the still image 27 s, the
first clip 99 s including loading LTX-2.5, the chained clip 78 s right after it (with the old order,
LTX-2.5 was reloaded before the chained clip and it took 98 s). Conform made 4 clips and 1 dissolve; the
export of 9 s at 1280 × 720 from the lossless copies took 5.9 s with NVENC, −14.0 LUFS, true peak
−2.5 dBTP. In the exported video the chained clip starts with the same knight in the same pose: the two
frames at the cut differ no more than neighbouring frames inside the first clip (22.1 against 21.0 dB
PSNR).

Be honest about the cost: 10 minutes made only of LTX-2.5 clips are 120 clips of 5 s, about 3 hours in
720p and 8.5 hours in 1080p. Still images with music and voice are much cheaper. Not there yet: voice
(text-to-speech), titles, subtitles, camera moves on still images, OpenTimelineIO.

### Recipe: an explainer video with a presenter

How a 30-second tutorial in the style of an animated explainer was built entirely through the MCP tools
(October 2026, RTX 5060 Ti 16 GB): a cartoon presenter who speaks at the start and at the end, three title
cards, three illustrating shots and music underneath. What carried over:

1. **Make the start images first, then the scenes.** LTX-2.5 invents a new face in every text-to-video
   scene, so a character who appears more than once needs start images. Make them with `generate_image`
   and `flux3-klein-nvfp4` in the video size (`width=1920, height=1088`, `batch_size=4`), style first
   ("3D animated film still in the style of a modern Pixar movie, …"), and pick at full resolution. For
   further shots of the same person pass the chosen one as `reference_asset_ids` ("The woman from the
   first image, with exactly the same face, glasses, curly hair and dark green hoodie, … medium close-up
   …"): 4 of 4 variants kept face, glasses, hair, clothing and room. Give each video scene its image as
   `params.image_asset_id`; the scene prompt then only describes motion, speech and sound.
2. **Speech comes from LTX-2.5.** Put the line in quotation marks with the voice ("says in a warm, cheerful,
   clear female voice: "…""), and add "Static camera, a locked-off shot; the framing stays exactly as in
   the first frame." Plan about 2 words per second: a line of 15 words ran into the last frame of a 6 s shot
   and was cut off mid-word, 11 words ended at 5.7 s, and the 13 words of the closing line at 4.2 s (LTX spoke
   2.2 and 3.3 words per second). Give the person something to do after the line ("Then she smiles and nods
   once."). Leave gestures out: "a single quick wave and lowers it back onto the desk right away" still gave
   2.5 s of waving, 1.4 s of it silent before the first word; with "her hands stay resting on the desk, and right
   away she says …" she started at 0.6 s. Use commas, not exclamation marks: after "Hi!" LTX paused 0.6 s,
   which sounded like a dropout over quiet music; after "Hi there," 0.3 s. Keep product names out of the
   spoken line: how
   the model pronounces an acronym is a gamble. Show the name instead (on a monitor in the start image, on a
   title card). You cannot hear the take: check that speech is there (the 300–3400 Hz band rises clearly
   above the room tone while the person talks) and ask the user to listen to the wording.
3. **Choose the quality per scene.** `params.quality` overrides the project's `video_quality`: `"dfr"` for
   the shots with a face and speech, `"standard"` for the illustrating shots. Measured here at
   1920 × 1088 from a start image: a 6 s DFR shot took 1519 s (25 min; its first DFR step alone took 6½ min
   while LTX-2.5 with the detail IC-LoRA was loaded into the 16 GB card), a 4 s standard shot 249 s.
4. **Title cards are image scenes.** `kind: "image"` with `qwen-image-2512-nvfp4` and
   `params: {"width": 1664, "height": 928}` (Qwen's native 16:9), the text in quotation marks: "A bright 3D
   cartoon title card in the style of an animated movie, centered composition. Big glossy rounded 3D letters
   in white with a lime green outline read "1. Write your scenes" … nothing else written anywhere." 3 of 3
   came out letter-perfect, 188–201 s each (50 steps). The export fills the 16:9 frame with them.
5. **Music is a scene on the `music` lane** with `stable-audio-3-medium`, one sentence with instruments,
   mood and tempo ("Playful warm orchestral pop underscore for an animated short with pizzicato strings,
   glockenspiel, light marimba, soft brushed drums and a bouncy upright bass, cheerful and curious like a
   cartoon tutorial. BPM: 112."): 30 s in 12.5 s. After `edit.conform` the music lies on A2; lower it under
   the speech with `clip.update` and `gain_db` (the tutorial used −9 dB).
6. **Say how long it takes, then let it run.** Add up the times above before you start (two DFR shots
   with speech make up most of it) and tell the user. The queue runs sound, title cards and videos in that
   order. Use `studio_generate(wait=False)` and poll `studio_get` every few seconds; finished scenes show up
   as takes, and the user can watch them arrive in the Studio tab.
7. **Check before conforming.** Look at three frames of every video take at full resolution (start, middle,
   end). For a scene that missed, set a new seed with `scene.update` (`params.seed`) and run
   `studio_generate(scene_ids=[…])`: the new take becomes the scene's take, the old one stays in its list and
   `scene.take` switches back if it was better. Then `edit.conform` and `studio_export`.

### Recipe: short comedy scenes with one character

Built in October 2026: more scenes for an existing photorealistic short film (1920 × 802, one character with a
blank stare in absurd war situations), eight gags of 8–9 s, 68 s in all, as one Studio project.

1. **Keep the format of the original.** Project 1920 × 802, video scenes with `params` 1920 × 832 (multiples of 64;
   3.6 % off, so the export crops 15 rows top and bottom). Measured with a start image: DFR at 1920 × 832 took
   305–326 s for 6 s and 242–245 s for 5 s, while 6 s at 1920 × 1088 took 1248–1519 s. The `project` export preset
   with NVENC and no bitrate wrote 16 Mbit/s.
2. **The face from the original** (a frame cropped to head and shoulders) as the reference image for FLUX 3, the
   clothing written out in the prompt, four variants per scene at 1920 × 832 (133–186 s); compare faces at full size.
3. **The joke has to be in the start image.** The user on the first laundry scene: the soldier "holds the washing line
   in the air, that is not funny". FLUX tied the line to the tank's gun barrel in 0 of 4 images, and the painter stood
   on a peaceful meadow in 0 of 4; the hammock strung between two howitzers came right in 4 of 4. When a connection is
   missing, edit the best variant: it as the first reference image, the face as the second, "Change only …, keep …
   exactly as in the first image". 4 of 4 correct, 204–207 s.
4. **Write the timing into the prompt.** "For the first two seconds nothing happens: …, then the tank suddenly fires"
   gave 1.3 s of calm build-up; without it the shot came after 0.2 s. For the deadpan look: "his face completely
   still, his eyes fixed on the distance".
5. **Extend instead of re-rolling** (the user: the clips should "run a little longer, like in the original, so the
   joke lands"): `generate_video(extend_asset_id=…, frames=73, quality="dfr")` adds 3 s of aftermath (146–150 s per
   clip, the seam 2.4–3.4 of 255). Then `scene.take` with that `asset_id`, lay the scenes out again, delete the old
   clips and run `edit.conform` (connected clips keep their in and out otherwise).

## Lossless copy of every video (since 0.5.13)

Every video model also writes the frames losslessly: FFV1 in MKV, 8-bit RGB, every frame a keyframe, sound
as 32-bit float PCM taken before the limiter. The MP4 stays the file for previews, browsers and Unity; the
copy is the source for editing. `generate_video` returns it in `lossless_files`; `master=False` skips it
when only the MP4 is needed. In the History each video asset carries it as `meta.master`
(`/files/<name>`); deleting the asset deletes it too, and extending a video joins the copies losslessly.

Measured (RTX 5060 Ti, LTX-2.5, 5 s): 161.7 MB at 1080p next to a 10.5 MB MP4 (about 32 MB per second),
78.4 MB at 720p (16 MB/s); written at 76 frames/s, round trip frame- and sample-exact. The MP4 (CRF 12,
4:2:0) against the copy: 41.3 dB PSNR, hardly visible. What it buys is the chain: the Studio's YouTube
export made from the copy reached 42.3 instead of 37.7 dB at the same file size, and a chain start image
taken from the copy is pixel-exact (from the MP4: 41.0 dB).

## Image to 3D

Two stages: first generate a suitable image, then run `image_to_3d` on it. TripoSG comes with
the Windows setup's full installation; TRELLIS.2 is only available when installing from source
(see [INSTALL.md](INSTALL.md#optional-3d-workers)).

**There is no text prompt for the mesh stage.** TRELLIS.2 and TripoSG work purely from the image.
The prompt affects the *image*, and the image fully determines the mesh.

That's why `text_to_3d(prompt)` is the most convenient route: it generates image and mesh in one
pass and automatically appends what the reconstruction needs.

```
text_to_3d("a weathered stone gargoyle", faces=60000)
```

Manually, in two steps:

```
1. generate_image("a single wooden barrel, medieval game asset, centered, isolated on
                   plain light grey background, floating, no ground, no shadow, product shot")
2. list_assets(kind="image", limit=1)      → asset_id
3. image_to_3d(asset_id, faces=40000)
```

**What's in the image ends up in the mesh.** The most common mistakes and their consequences:

| In the image | In the mesh |
|---|---|
| Floor, table edge, ground | an extra ground plate under the object |
| Cast shadow under the object | a flat plate under the model |
| Gradient background, vignette, fog | floating strands and thin pillars |
| Two objects or a sprite sheet | fused nonsense |

**A base that belongs to the object is not an error.** A sphinx statue stands on its stone slab,
a monument on its pedestal — that belongs in the mesh. Exclude only what the object is
additionally *placed* on: floor, table, cast shadow.

So the image prompt should include: `the complete object including any base that belongs to it,
plain flat background, no cast shadow, not standing on a floor or table`.
And the negative prompt: `cast shadow, floor, ground plane, table surface, environment` —
**not** `pedestal` or `base`, which would prompt away the object's own base.

Two adjustments if it still goes wrong:

- **`background_mode="birefnet"`** (default) uses a segmentation model and gives much cleaner
  edges than `"flood"`, which only removes connected border areas of similar color and fails on
  soft gradients.
- **`clean_specks=True`** (default) throws out floating fragments. It only catches loose parts —
  whatever sticks to the main body has to be prevented through the image.

**Lettering and stickers: `project_front=True`** (since 0.5.10, `image_to_3d` and `text_to_3d`) puts
the cut-out source image onto the faces that point to the camera, so lettering stays readable;
TripoSG builds painted letters only as a garbled relief. The rest of a TripoSG mesh gets colors from
the image, a TRELLIS.2 mesh keeps its texture there (not tested yet). Measured on a direction sign
reading "HAFEN": readable with the projection, ~66 s for the whole mesh, the projection itself under
1 s. Faint relief strokes of the TripoSG letters remain visible.

Two models with clearly different results:

| | TripoSG | TRELLIS.2-4B |
|---|---|---|
| Output | geometry only | **geometry + PBR textures** |
| Time | ~60 s warm | ~145 s |
| VRAM | ~10 GB | ~14 GB |
| License | MIT | MIT |

**TRELLIS.2** delivers albedo and metallic/roughness as real 2048² bitmaps with UVs — that makes
an asset usable without manual texturing. Parameters: `texture_size` (1024/2048/4096) and `faces`
(default 100,000). The voxel resolution stays at 512³; 1024³ doesn't fit into 16 GB.

**TripoSG** is faster and more frugal, but delivers an untextured mesh. Useful if you put your
own materials on it anyway. `faces=-1` keeps the full mesh (~200k, usually too much for Unity),
otherwise 10,000–40,000.

Neither mesh is guaranteed to be watertight, and both benefit from retopology before they go into
a game. Tell the user that instead of passing off a raw result as a finished asset.

## VRAM: one card, one model

16 GB holds exactly one model. The server serializes GPU jobs itself — but:

- Before a model that needs >13 GB of VRAM (Wan 2.2 I2V A14B, Chroma bf16), it pays to call
  `POST /api/backend/free` or use the **Free VRAM** button in the web UI.
- `image_to_3d` frees ComfyUI's memory **automatically** before TripoSG loads. After that, the
  next image job needs a fresh model load — plan for it: generate all images first, then all
  meshes.
- Downloads run in a **separate queue** and don't block the GPU.

**Several graphics cards (since 0.5):** without a choice of your own, everything runs on the strongest
card (memory first, then compute capability). Splitting the work brought no gain in measurements with an
RTX 5060 Ti 16 GB plus an RTX 4060 8 GB on a PCIe 3.0 x4 riser: FLUX 3 took 29 instead of 9 s on the
4060, Qwen-Image-2512 1095 instead of 97 s, and moving the text encoder to the second card saved
nothing. `GET/PUT /api/gpus` assigns image models, language models (upsampler, prompt expansion) and 3D
to a card each; with the language models on their own card, prompt expansion runs in parallel to image
jobs (7.5–8.6 s per expansion on the 4060). Full load on both cards at once once made the 4060 drop off
the bus (a repeat two days later with a newer driver ran clean), so ask the user before running both.

**AMD Radeon (experimental, since 0.5.12 with ROCm 10):** the setup installs PyTorch 2.13 with ROCm 10.0
(AMD's multi-architecture packages, as in ComfyUI's README) and falls back to ROCm 7.2.1 if a test
computation on the card fails. Nothing is measured on a real Radeon yet. Do not use the `-nvfp4` ids there:
`list_models` marks the matching versions as `recommended` and explains the others in `gpu_note` — on a
Radeon RX 9000 with 16 GB `qwen-image-2512-fp8`, `flux3-klein-bf16`, `krea2-turbo-fp8`,
`moss-image-sft-bf16`, `z-image`, `ltx25-distilled-int8` and `seedvr2-7b-fp8`; on other Radeons the INT8
versions. 3D needs an NVIDIA card. Prompt expansion uses FLUX 3's W4A8 upsampler, which comfy-kitchen
computes with its own HIP kernels on RDNA3 and RDNA4.

## Licenses — before using assets in a game you sell

`list_models` returns `commercial_ok`. Critical cases:

- **Hunyuan3D** — Tencent Hunyuan Community License, not licensed in the EU, the UK and South Korea. Replacement: **TripoSG** (MIT).
- **Stability Community License** (Stable Audio Open, Stable Audio 3) — commercial use up to
  US$1 million in revenue.
- **FLUX Kommunity License v1.0** (FLUX 3 Image Klein) — images may be used commercially only by
  "Qualifying Users" below US$5 million annual revenue, including affiliated companies.
  Conditions (section 2.e): a content filter **or** reviewing every image for unlawful and
  infringing content before publishing it; AI labeling where the law requires it. BFL can
  terminate the license at any time by notice (8.b). The images must not be used to train any
  other image model (4.b). No EU exclusion. The repo is gated — accept the license on Hugging
  Face and store a token. Without these conditions: **Qwen-Image-2512** (Apache-2.0).
- **Krea 2 Community License** (Krea 2 Turbo) — commercial use only below US$1 million annual
  revenue, including affiliated companies; a content filter **or** a review of every image by hand;
  AI labeling where the law requires it; Krea can terminate the license with 30 days' notice. The
  files come from Comfy-Org/Krea-2 (not gated). Without these conditions: **Qwen-Image-2512**
  (Apache-2.0).
- Unproblematic: SDXL, FLUX schnell, Wan (all variants), Chroma, TripoSG, TRELLIS.2.

`list_models` also returns `content` (`uncensored`, `partial`, `censored` or null for unknown)
with `content_note` and `content_source`. NVAI-open itself has no content filter.

When in doubt, point the user to the license instead of generating silently. This is not legal
advice; the original license text is authoritative.

## Reading errors correctly

- **`clip input is invalid: None`** → The checkpoint has no text encoder; the model is missing
  files. `list_models` shows which. Don't tinker with the prompt.
- **`No <kind> model installed`** → `list_models(kind=...)`, then suggest a download.
- **`… is an image-to-video model — please provide a start image`** → `image_asset_id` is
  missing. Either generate an image and pass its asset ID, or choose a T2V model.
- **Timeout while starting the backend** → `GET /api/backend/log` (or `?worker=triposg`) shows
  the real reason.
- **Job stays `queued`** → A GPU job is already running. Downloads don't block.
- **`No access to … the repo is gated`** → The license of that Hugging Face repo is not accepted yet, or
  with a different account than the stored token's. Retrying does not help: point the user to the
  illustrated guide ([HUGGINGFACE.md](HUGGINGFACE.md)); the model card shows when access works.

## Getting assets into the game

```
copy_asset(asset_id, "C:/path/to/UnityProject/Assets/Generated/")
```

Unity imports it on its own. For meshes, `Unity_ImportExternalModel` with the path returned by
`image_to_3d` is the more direct route.

A sensible location: `Assets/Generated/Textures|Audio|Video|Meshes/`. Don't mix generated assets
into existing folders without asking.
