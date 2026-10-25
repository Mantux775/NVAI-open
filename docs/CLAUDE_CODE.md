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
| `list_assets` / `delete_asset` / `clear_history` | History |
| `copy_asset` | Copy an asset to `Assets/Generated/` or similar |

All `generate_*` tools **block until done** and return absolute file paths.

## Workflow

1. `health` — is everything running, is a model of the needed category active?
2. If one is missing: `list_models(kind=...)` → `download_model` → `set_active_model`
3. Generate
4. `copy_asset` into the target project, or pass the path straight to `Unity_ImportExternalModel`

When a model is missing, **don't guess** — `list_models` shows size, VRAM requirement and
license. Downloads are several GB; ask the user first.

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
| Audio 6 s SFX, 50 steps | Stable Audio Open | ~12 s |
| Music 60 s / 20 s | ACE-Step 1.5 Turbo (8 steps, CFG 1, shift 3) | ~17 s / ~10 s |
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
| DFR 1280 × 704, 4 s / with 48 fps | LTX-2.5 NVFP4 | ~118 s / ~294 s |
| Extend a video, 5 s + 4 s, 1920 × 1088 | LTX-2.5 NVFP4 | ~255 s for the new part including joining |
| Video with sound 1280 × 704, 4 s | LTX-2.3 NVFP4 | ~101 s; image to video 448 × 832 ~65 s |
| Video 848 × 480, 49 frames | Mochi 1 preview fp8 | ~351 s with loading |
| Video 768 × 512, 5 s | Kandinsky 5 Lite distilled | ~300 s; 50 steps (T2V, I2V) ~26–27 min |
| Mesh from image | TripoSG | ~180 s cold, ~60 s warm |
| Mesh with the front from the image | TripoSG | ~66 s warm, the projection itself under 1 s |

The first job after a start costs an extra ~15–30 s of model loading. For video and 3D, warn the
user up front instead of leaving them waiting.

## Images

### Model choice: the three recommended models

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

## Audio

Three different models — adapt the prompt style to the model:

**Stable Audio Open** → sound effects and ambience. Describe the **sound**, not the music:

```
"heavy metal sword clash, single impact, bright metallic ring, dry studio recording"
"footsteps on gravel, close mic, no music"
"rain on canvas tent, distant thunder, loop"
```

Up to 47 s. For loops, generate generously and let the user trim.

**ACE-Step** → music with structure and vocals. **Genre tags**, comma-separated, plus optional
`lyrics`:

```
prompt: "epic orchestral, choir, war drums, cinematic, minor key"
lyrics: ""            # empty = instrumental
```

**ACE-Step 1.5** takes tempo, time signature and key directly: `bpm`, `time_signature` ("2" =
2/4, "3", "4", "6" = 6/8) and `key_scale` ("Bb major", "A minor"). Without them 120 BPM, 4/4 and
C major apply. A march: 120 BPM, "2", "Bb major". Since 0.5.7 NVAI-open runs it like ComfyUI's
template (8 steps, CFG 1, shift 3); before it used 12 steps and CFG 2 without shift, which
sounded harsh and compressed.

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
(ceiling −1 dBFS). ACE-Step is lowered by 3 dB first: its raw output peaks up to +5.7 dBFS, and
the MP3 encoder used to cut everything above 0 dB off hard. Measured with the limiter: ACE-Step
−14 to −17 LUFS, Stable Audio 3 −12 to −15 LUFS, true peak at most +0.2 dBTP (MP3 overshoot).
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
- Unproblematic: SDXL, FLUX schnell, ACE-Step (1.5: MIT, v1: Apache-2.0), Wan (all variants), Chroma, TripoSG, TRELLIS.2.

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

## Getting assets into the game

```
copy_asset(asset_id, "C:/path/to/UnityProject/Assets/Generated/")
```

Unity imports it on its own. For meshes, `Unity_ImportExternalModel` with the path returned by
`image_to_3d` is the more direct route.

A sensible location: `Assets/Generated/Textures|Audio|Video|Meshes/`. Don't mix generated assets
into existing folders without asking.
