# Image models in NV-AI: Qwen-Image-2512 and FLUX 3 Image Klein

*Deutsch: [de/MODELLE.md](de/MODELLE.md)*

A reference for projects that generate images through NV-AI. It applies to Claude Code with
the `nvai` MCP server as well as to your own programs using the REST API. It describes the two
image models NV-AI recommends: what they can do, how to address them, how long they take and
where they fail.

As of October 18, 2026. Measured on an RTX 5060 Ti 16 GB (ComfyUI 0.41.3, PyTorch 2.11 cu130).
All times and findings were measured there. Statements that come from the vendor are marked as
such ("according to BFL").

---

## 1. At a glance

| | **Qwen-Image-2512** | **FLUX 3 Image Klein** |
|---|---|---|
| Model ID | `qwen-image-2512-nvfp4` | `flux3-klein-nvfp4` |
| Vendor | Alibaba (Qwen) | Black Forest Labs, October 2026 |
| Size | 20B parameters, NVFP4 | 5.6B parameters, NVFP4 |
| Text encoder | Qwen2.5-VL-7B | Qwen3-VL-4B, plus a prompt upsampler (Qwen3.5-9B) |
| Steps / CFG | 50 / 4.0 | 16 / 1 (distilled) |
| Negative prompt | works; empty = default from Qwen's model card | has **no** effect |
| Reference images | — | up to 10 |
| Placement by box | — | yes |
| Text in the image | letter-perfect | 3 of 3 error-free in testing |
| Time per 1024² image | ~100 s | ~30 s for a new prompt, 13–16 s for a known one |
| License | **Apache-2.0** | **FLUX Kommunity License** — revenue cap, review obligation |
| Strengths | final assets, structural details, text | editing, consistent characters, layout, speed |

## 2. Which model for what

| Task | Model |
|---|---|
| Final asset without a template: object, figure, icon, scene | **Qwen** |
| Text, lettering, signs | **Qwen** |
| Construction must be right (fastenings, hinges, handles) | **Qwen** |
| Change an existing image in a targeted way: replace a part, color, material | **FLUX 3** with the image as a reference |
| The same character or object across several images | **FLUX 3** with a reference image |
| Combine subjects from several images | **FLUX 3** with several references |
| Several objects at fixed positions | **FLUX 3** with bounding boxes |
| Quick drafts | FLUX 3 (13–16 s) or Qwen Lightning (`qwen-image-2512-lightning`, ~17 s) |
| Historically accurate vehicles (Panzer IV, Sd.Kfz. 251 …) | **none** — see section 8 |

Without a `model_id`, NV-AI uses the active image model.

## 3. Access from other projects

### Prerequisite

The NV-AI server must be running. It listens on `http://127.0.0.1:8100`. With the Windows setup,
start it from the Start menu (**NV-AI**); in a source checkout:

```powershell
scripts\start.ps1     # reports if it is already running
```

The GPU backend (ComfyUI) starts by itself with the first job. That costs about 30 s once and
is not an error. `health` shows whether everything is running and which model is active.

### Via MCP (Claude Code)

Register the `nvai` MCP server once **at user scope**; it is then available in every Claude
Code project without further setup:

```
claude mcp add --scope user nvai -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

With the Windows setup, also pass your data folder (`-e "NVAI_DATA_DIR=<data folder>"`), see
[CLAUDE_CODE.md](CLAUDE_CODE.md).

The most important tools:

| Tool | Purpose |
|---|---|
| `health` | always first: backend, active models, queue |
| `list_models(kind="image", detailed=True)` | models with `features` (section 7), pros and cons, license |
| `generate_image(...)` | generates images and blocks until done. Returns `files`, `asset_ids`, `seed`, and for FLUX 3 also `caption` |
| `list_assets(kind="image")` | latest images with asset ID and path |
| `copy_asset(asset_id, destination)` | copy an image into your own project |

After an NV-AI update, a running session only sees the new tool descriptions after `/mcp` and
reconnecting.

### Via REST

| Method and path | Purpose |
|---|---|
| `GET /api/health` | status |
| `GET /api/version` | program, ComfyUI and contract version (`api`), supported extensions (`features`: `mask`, `references`, `upsampler` …). Check before first use |
| `GET /api/models?kind=image` | models with `features`, plus `recommended` and `gpu_note` for the detected card |
| `GET /api/models/search?q=…` | more models on Hugging Face (repos with checkpoint files) |
| `GET /api/models/inspect?repo=…&file=…` | checks a file before downloading: architecture from the safetensors header, size. SDXL and SD 1.5 checkpoints can be downloaded |
| `POST /api/generate/image` | create a job (JSON, fields as in section 6). Response: job with `id` |
| `GET /api/jobs/{id}` | `status` (`queued`, `running`, `done`, `error`), `progress` 0–1, `stage` |
| `GET /api/jobs/{id}/assets` | generated images: `id`, `filename`, `url`, `meta` (seed, settings, and `caption` for FLUX 3) |
| `POST /api/upload` | upload your own image (multipart, field `file`). The returned `id` works as a reference image |
| `GET /files/{filename}` | image file |

The files are stored directly in `<data folder>\assets\<filename>`: `data\assets` in a source
checkout, `%LOCALAPPDATA%\NV-AI\assets` with the setup's default data folder.

From another device (server started with `scripts\start.ps1 -Lan`) this folder does not exist.
Load images via `GET /files/{filename}` instead. Every request needs the `X-NVAI-Token` header,
including those to `/files`; without a valid token the server answers with 401. `/api/version`
works without a token and shows under `authorized` whether the one you sent is valid. The REST
API is specified in `server/openapi.json` (contract version `api`).

```python
import json, time, urllib.request

API = "http://127.0.0.1:8100"

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())

job = call("POST", "/api/generate/image", {
    "model_id": "qwen-image-2512-nvfp4",
    "prompt": "Studio product photograph of a weathered wooden ammunition crate. ...",
    "width": 1024, "height": 1024, "seed": 42,
})
while (j := call("GET", f"/api/jobs/{job['id']}"))["status"] not in ("done", "error"):
    time.sleep(2)
for asset in call("GET", f"/api/jobs/{job['id']}/assets"):
    print(asset["id"], r"<data folder>\assets" + "\\" + asset["filename"])
```

The server processes GPU jobs one after another. If a job is `queued`, another one is currently
running.

## 4. Qwen-Image-2512 (`qwen-image-2512-nvfp4`)

### Key facts

- 20B parameters (MMDiT). In bf16 that would be 41 GB. The NVFP4 quantization used here
  (`Hippotes/Qwen-Image-2512-quants`, version v2) weighs 14.9 GB, and RTX 50 cards compute this
  format in hardware.
- Text encoder Qwen2.5-VL-7B (fp8, 9.4 GB), VAE from Qwen. Total download 24.5 GB.
- 50 steps, CFG 4.0, sampler `euler`, scheduler `simple`, shift 3.1. The values come from
  ComfyUI's template and Qwen's model card.
- License Apache-2.0: commercial use without restriction.

### What it does well

- **Letter-perfect text in the image.** Crate lettering and signs come out exactly as written in
  quotation marks in the prompt.
- **Construction.** In testing, the rope handles of an ammunition crate ran through drilled
  holes and under the battens. With the same seed, the distilled Lightning version laid them on
  the wood without any attachment.
- **Long prompts.** The encoder is a language model; there is no 77-token limit as with CLIP.
- **The negative prompt works** (CFG 4). If it is left empty, NV-AI inserts the one from Qwen's
  model card:
  `低分辨率，低画质，肢体畸形，手指畸形，画面过饱和，蜡像感，人脸无细节，过度光滑，画面具有AI感。构图混乱。文字模糊，扭曲。`
  It stands for low resolution, deformed limbs and fingers, oversaturation, a waxy look, an AI
  look, a chaotic composition and distorted text.
- **Image as a starting point** (`image_asset_id` + `denoise`): an almost-right image is refined
  instead of rerolled.
- **Inpainting** (`image_asset_id` + `mask_asset_id` + `denoise=1.0`): only the white area of the
  mask is regenerated, black is kept, gray levels blend smoothly. Measured: inside the mask, a
  crate's lettering "MUNITION 7,92" became "FLAK 88" in the same stencil font. Outside the mask
  the image deviated by 0.6 out of 255 on average, i.e. only by the noise of the VAE round trip.
  With 28 steps this took 82 s including a cold start. Use the full model for new objects. In
  testing, Lightning mostly just continued the surroundings, which is enough for retouching
  something out.
- **Second pass** (`hires=True`) for hands, faces and fine technical detail.

### Sizes

The general sizes around 1 megapixel work. But Qwen is trained at about 1.76 MP, and its
**native sizes** give visibly more detail:

| Native | Aspect ratio | Use for |
|---|---|---|
| 1328 × 1328 | 1:1 | objects, icons |
| 1056 × 1584 | 2:3 | standing figures |
| 1584 × 1056 | 3:2 | vehicles, scenes |
| 1104 × 1472 / 1472 × 1104 | 3:4 / 4:3 | |
| 928 × 1664 / 1664 × 928 | 9:16 / 16:9 | panoramas |

Measured at 1328² versus 1024²: finer rope twist and wood grain, at twice the time.

### Run times (measured)

| Run | Time |
|---|---|
| 1024², 50 steps | ~100 s (1.84 s per step) |
| 1328² native, 50 steps | ~200 s (3.79 s per step) |
| Lightning, 1024², 8 steps | ~17 s, four images ~40 s (measured with ComfyUI 0.30) |
| first job after startup | plus 15–30 s for loading |

### Writing the prompt

Full English sentences. First medium and style, then the subject with material, color,
condition and construction, then lighting and background. Text verbatim in quotation marks.

```
Studio product photograph of a weathered wooden ammunition crate. Black stenciled letters on
the front read "MUNITION 7,92". Rope handles pass through drilled holes in the side boards.
Plain light grey background, soft even light.
```

- **State the construction explicitly.** Whatever is not written down gets invented.
- **No weighting brackets** like `(full body:1.2)`. That is CLIP syntax and has no effect here.
- **Name the origin of people**, as region plus facial features: *Central European soldiers
  with pale northern European features*.
- Name **exactly one view** ("strict side view"), not two.

### Known limits

- It invents historical vehicles: in testing, "Kübelwagen" became a Willys Jeep.
- With Lightning (8 steps), structural details get lost. Lightning is only suitable for drafts.
- Encoder and model do not fit into 16 GB at the same time. Every new prompt reloads; that is
  already included in the measured times.

## 5. FLUX 3 Image Klein (`flux3-klein-nvfp4`)

### Key facts

- Black Forest Labs, released on October 15, 2026. 5.6B parameters in the image model, official
  NVFP4 version from BFL (5.3 GB).
- Text encoder Qwen3-VL-4B (int8, 4.9 GB), prompt upsampler Qwen3.5-9B (int8, 9.8 GB), VAE from
  FLUX.2. Total download 20.2 GB.
- Distilled: 16 steps without guidance (CFG 1). According to BFL, it is the same model that runs
  behind their API.
- The repo on Hugging Face is gated. Accept the license once, then enter a Hugging Face token in
  the web UI under **Models**, or in a source checkout run
  `server\.venv\Scripts\hf.exe auth login`.

### The prompt upsampler

FLUX 3 is trained on long image descriptions written by its own upsampler. BFL advises never to
use the model without it. In NV-AI it therefore runs automatically before every image:

1. From the request, the upsampler writes a description of 100 to 350 words. For non-square
   sizes it is told the aspect ratio and composes for it.
2. The image is generated from this description.
3. The description is returned as **`caption`**: directly in the return value via MCP, and in
   the asset's `meta.caption` via REST.

It decodes deterministically: the same prompt always yields the same description. NV-AI caches
it, so a new seed with the same prompt only costs the image time. The cache lives in the server
process and is empty after a restart.

`upsample_prompt=False` turns the upsampler off. That is only worthwhile if the prompt itself is
already a full description in this style. Without the upsampler, the test crate came out plainer
and smaller.

**What this means for the prompt:** short and complete is enough. But the upsampler fills every
gap on its own. In testing it draped a greatcoat over soldiers' backs like a cape, gave them
lace-up shoes instead of marching boots, and let rope handles hang loosely across the front of a
crate. Everything that has to be right therefore belongs in the prompt, and the **style** belongs
at the beginning. Without a style, the upsampler plans a photo.

If something in the image is wrong, read `caption` first. If the error was already there, extend
the prompt instead of rerolling.

### Reference images

`reference_asset_ids` takes up to ten asset IDs: generated images or your own uploads
(`POST /api/upload`). In the prompt they are called, in this order, "the first image", "the
second image", and so on.

**Editing** (one reference image): the prompt says what changes and what stays the same.

```
generate_image(
  prompt="Replace the rope handles with forged iron handles bolted to the side boards; "
         "keep everything else unchanged.",
  model_id="flux3-klein-nvfp4",
  reference_asset_ids=["ast_b2e2b512098a"],
)
```

In testing, the source stayed the same except for the handles: boards, stencil lettering and
battens were unchanged, and the new handles are bolted on with plates. However, the model added
three handles instead of two, one of them on the front batten.

**Combining and consistency** (several references):

```
prompt="Put the soldier from the first image into the trench from the second image, "
       "same uniform and helmet, seen from the side."
```

If FLUX 3 gets only an `image_asset_id` and no `reference_asset_ids`, the image becomes the first
reference; `denoise` does not apply then.
The output size is set by `width` and `height`, not by the reference. References are fed in at
about 1 MP.

According to BFL, references anchor the content but do not fix the shape. A blueprint as a
reference therefore does not turn an invented vehicle into a true-to-scale one.

### Placement with bounding boxes

Append a JSON list to the end of the prompt. Each box is `[top, left, bottom, right]` on a grid
from 0 to 1000, with the origin at the top left:

```
Studio product photograph of three separate weathered wooden ammunition crates standing side
by side on a plain light grey background, soft even light.
[{"id": "crate_1", "bbox": [430, 30, 820, 320], "desc": "a small crate with a hinged lid"},
 {"id": "crate_2", "bbox": [250, 350, 820, 650], "desc": "a tall crate with rope handles"},
 {"id": "crate_3", "bbox": [560, 680, 820, 970], "desc": "a flat, wide crate"}]
```

In testing, all three crates stood exactly at their boxes. This lets you fix count and
arrangement, which diffusion models do not reliably achieve from text alone.

- **Do not cite the ids in the text as `<crate_1>`.** The upsampler does that, and the boxes stay
  fixed. If the text cites all ids, it counts as a finished description and goes to the model
  without the upsampler. That is how BFL's reference code does it.
- The boxes steer position and size but are not a hard mask. An element can extend beyond its
  box; very small elements can be missing.

### Sizes

Sides must be multiples of 16. The general 1 MP sizes work. According to BFL, the model works
natively up to 4K; the NV-AI API allows up to 2048 × 2048. In measurements, 1440² brought more
detail, for example a rope running through an eyelet with a metal ring, at 26 instead of 13 s.
FLUX 3 has no second pass (`hires`). If you want more detail, choose a larger size directly.

### Run times (measured)

| Run | Time |
|---|---|
| new prompt, 1024² | ~30 s (upsampler 8–15 s, image ~12 s) |
| same prompt, new seed | 13–16 s |
| four images in one run | ~37 s |
| 1440 × 1440 | ~26 s |
| editing with one reference image | ~45 s |
| box layout (upsampler in layout mode) | ~36 s |

In testing, FLUX 3 and Qwen ran alternately without out-of-memory errors. ComfyUI used up to
15.5 GB, because it keeps models in memory as long as there is room.

### Test findings (11 cases, images checked at full resolution)

| Checked | Result |
|---|---|
| Text "MUNITION 7,92" | 3 of 3 error-free (BFL itself warns that text may be inaccurate) |
| Soldiers, portrait format | 5 of 5 complete with feet, helmet shape correct. Invented: a greatcoat worn as a cape, and lace-up shoes |
| Rope handles | 3 of 3 without a sensible loop, only once (1440²) through an eyelet |
| Editing | source unchanged except for the handles |
| Boxes | 3 of 3 crates at the specified position |
| Scene "Kübelwagen" | oil painting, German helmets correct. Instead of the Kübelwagen, a small flatbed truck appeared |
| without a style | photorealistic |

### Base version (`flux3-klein-base-nvfp4`)

This version is undistilled: 50 steps, CFG 3.5, and the negative prompt works. BFL offers it
mainly for fine-tuning and LoRA training. Measured, it takes 53 s per image. In testing it
brought no visible gain over the distilled version.

### INT8 version for RTX 20/30/40 (`flux3-klein-int8`)

Only RTX 50 cards compute NVFP4 in hardware. Older cards can load it, but unpack it layer by
layer and are much slower. For them there is BFL's official INT8 version
(`flux3-image-klein-int8-convrot`, 5.8 GB). INT8 runs in hardware on every NVIDIA card from the
RTX 20 series on. As in BFL's own INT8 template, it comes with the smaller upsampler (w4a8,
6.7 instead of 9.8 GB). According to BFL, this runs on 8 GB cards such as the RTX 3070, and on an
RTX 4070 in under 9 s per image (16 steps, 1 MP). We have not measured this yet. Prompts,
reference images, boxes and the upsampler work as with NVFP4.

NV-AI detects the card (`compute_cap` via nvidia-smi) and marks suitable models in
`list_models` with `recommended`: on RTX 50 Qwen and FLUX 3 in NVFP4, on older cards FLUX 3 INT8
and Z-Image INT8. A format that the detected card does not compute in hardware gets a note in
`gpu_note`.

### License: FLUX Kommunity License v1.0

This is not legal advice; the full text in the model repository (`LICENSE.md`) is authoritative.

- Commercial use of the images is only allowed for "Qualifying Users": annual revenue, together
  with affiliated companies, below US$5 million (sections 1.e and 2.a).
- Conditions (section 2.e): either use a content filter **or** review every image for unlawful
  and infringing content before publishing it. In addition, AI labeling where the law requires
  it.
- BFL can terminate the license at any time by notice (8.b).
- The images must not be used to train any other image model (4.b).
- No EU exclusion.
- The text encoder and the upsampler are under Apache-2.0.

Point out this license for every FLUX 3 image that goes into a product that is sold. If these
conditions don't work for you: Qwen.

## 6. `generate_image` parameters

Applies equally to the MCP tool and to the body of `POST /api/generate/image`.

| Parameter | Qwen-50 | FLUX 3 | Note |
|---|---|---|---|
| `prompt` | detailed, full sentences | short and complete, style first | |
| `negative_prompt` | works; empty = model card default | no effect | ~10 terms, no style bans |
| `model_id` | `qwen-image-2512-nvfp4` | `flux3-klein-nvfp4` | empty = active model |
| `width`, `height` | multiples of 8, native ~1.76 MP | multiples of 16, up to 2048 | size by silhouette |
| `steps`, `cfg` | 50 / 4.0 | 16 / 1 | leave empty = model default |
| `sampler`, `scheduler` | euler / simple | euler / simple | avoid `karras` and `exponential` |
| `seed` | ✓ | ✓ | |
| `batch_size` | ✓ | ✓ (4 images ~37 s) | one model load instead of many |
| `hires`, `hires_scale`, `hires_denoise` | ✓ | — | |
| `image_asset_id` + `denoise` | refine an image | becomes the first reference | |
| `mask_asset_id` | ✓ inpainting (with `image_asset_id`, `denoise=1.0`) | — (error message) | white = new, black = keep; upload the mask via `POST /api/upload` |
| `reference_asset_ids` | — | up to 10 | error message with other models |
| `upsample_prompt` | — | on by default | |
| `slg`, `controlnet_*` | — | — | only for SD 3.5 models |

Size by silhouette: standing figure 832 × 1216 (Qwen native 1056 × 1584), vehicle in landscape
1216 × 832 (1584 × 1056), object and icon 1024 × 1024 (1328 × 1328).

## 7. The `features` field

`GET /api/models` and `list_models(detailed=True)` return a `features` field for each image
model. Other programs can adapt their controls to it, as the NV-AI web UI does.

| Key | Meaning | Qwen-50 | FLUX 3 |
|---|---|---|---|
| `steps`, `cfg` | defaults | 50, 4.0 | 16, 1.0 |
| `negative_prompt` | does the negative prompt work? | true | false |
| `default_negative` | applies when none is given | Qwen's default | empty |
| `upsampler` | prompt upsampler available | false | true |
| `references` | maximum number of reference images | 0 | 10 |
| `bbox` | placement by box | false | true |
| `img2img` | start image with `denoise` | true | false |
| `mask` | inpainting with `mask_asset_id` | true | false |
| `hires` | second pass useful | true | false |
| `text_rendering` | text in the image | true | true |
| `sizes` | additional recommended sizes `{label, w, h}` | 7 native | 4, up to 2048² |
| `prompt_hint` | short prompt guide, in the request language (English by default) | ✓ | ✓ |
| `placeholder` | example prompt | ✓ | ✓ |

## 8. Known pitfalls

- **Historical vehicles:** no model knows the silhouette of a Panzer IV or a Kübelwagen. More
  seeds only give other fantasy vehicles. Fidelity would need a template plus a ControlNet, and
  none is integrated for either model.
- **The FLUX 3 upsampler fills gaps with inventions:** write what matters explicitly into the
  prompt and check `caption`.
- **Box ids cited in the text:** then no upsampler runs, see section 5.
- **Negative prompt with FLUX 3 and Lightning:** it is not computed at all. Phrase exclusions
  positively, e.g. *plain light grey background* instead of *no background*.
- **PyTorch cu130 is required for NVFP4.** With cu128, ComfyUI disables its NVFP4 kernels and
  everything becomes three to five times slower. `setup_comfyui.ps1` installs cu130.
- **ComfyUI 0.41 or newer** for FLUX 3. `install.ps1` pins v0.41.3.
- **Check results at full resolution:** downscaled previews hide exactly the errors that matter,
  such as a rope handle without a hole.

## 9. For maintainers

| What | Where |
|---|---|
| Catalog entries, `features`, texts | `server/nvai/catalog.py` |
| ComfyUI graphs (`build_qwen_image`, `build_flux3`) | `server/nvai/workflows.py` |
| Upsampler, box logic, cache | `server/nvai/flux3_prompt.py` (based on BFL's reference code, Apache-2.0) |
| BFL's upsampler system prompts | `server/nvai/flux3_pup_prompts.json` |
| Flow (upsampler, then image; providing references) | `server/nvai/jobs.py`, `_txt2img` |
| MCP instructions and tool texts | `server/nvai/mcp_server.py` |
| Model files | `external/comfyui/models/{diffusion_models,text_encoders,vae,loras}` (the Windows setup uses the model folder chosen during installation) |

The graphs are modeled on the templates that ship with ComfyUI: `image_qwen_Image_2512.json` and
`image_flux3_klein_*`. The CLIPLoader types are `qwen_image` and `flux3`, the empty latent is
`EmptySD3LatentImage` or `EmptyFlux2LatentImage` respectively, references go through
`ReferenceMultiLatent`, the upsampler through `TextGenerate`.
