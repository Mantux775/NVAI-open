# Using NVAI-open from Claude Code

NVAI-open includes an MCP server, `nvai`, that gives Claude Code local media generation on the user's own graphics
card: images, video with sound, music, 3D meshes, restored photos and whole videos in the Studio. The MCP server is a
thin client of the NVAI-open REST server, so the web interface and Claude Code share the same job queue and history.

This guide covers the setup, the tools and what we measured about models, prompts and settings, on an RTX 5060 Ti with
16 GB. Copy the parts you need into a project's `CLAUDE.md`.

## Setup

**The server must be running.** All tools talk to `http://127.0.0.1:8100`; without it every tool fails. With the
Windows setup, the Start menu entry **NVAI-open** starts it and **Quit NVAI-open** stops it; in a source checkout use
`scripts\start.ps1` and `scripts\stop.ps1`. The GPU backend (ComfyUI) starts with the first job, which takes about 30 s
once; that is not an error.

**Register the MCP server** once at user scope, so it is there in every project:

```
claude mcp add --scope user nvai -e "NVAI_DATA_DIR=<data folder>" -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

`<install folder>` is the program folder of the setup (default `%LOCALAPPDATA%\Programs\NV-AI`) or the repository of a
source checkout. `NVAI_DATA_DIR` tells the MCP server where the files are, so the paths it returns are right (setup
default `%LOCALAPPDATA%\NV-AI`; a source checkout can leave it out). If NVAI-open listens on another port, add
`-e "NVAI_API_URL=http://127.0.0.1:8101"`. After an update, `/mcp` and reconnecting load the new tool descriptions.

## Tools

| Tool | Purpose |
|---|---|
| `health` | Always first: backend, active models, queues |
| `list_models` | Catalog; `kind=` filters, `detailed=true` adds pros, cons and `features` |
| `download_model` / `delete_model` / `set_active_model` | Model management |
| `generate_image` | Image → file paths |
| `expand_prompt` | A few words → a full prompt; `target` = `image`, `video`, `video_sound`, `video_start`, `video_multishot`, `sfx`, `music_sa3` or `3d` (needs FLUX 3 downloaded) |
| `generate_audio` | Sound effect or music → file paths |
| `generate_video` | Clip → file paths; `wait=False` returns the `job_id` at once |
| `job_status` | State of a job; `wait_s` up to 600 waits for it; once done, the same result as the `generate_*` call |
| `image_to_3d` / `text_to_3d` | Image (or text → image) → GLB mesh |
| `restore_image` | Old photo → repaired, colorized and/or sharpened |
| `list_assets` / `delete_asset` / `clear_history` | History |
| `copy_asset` | Copy an asset into a project, e.g. `Assets/Generated/` |
| `studio_*` | Studio projects: scenes, generating, conforming, cutting, export ([Studio](#studio-whole-videos-from-scenes)) |

`list_models(kind="lora")` lists downloaded LoRAs with family and trigger words; pass them as
`loras=[{"model_id": "…", "strength": 0.8}]` (a model's `lora_bases` says which fit).

All `generate_*` tools **block until done** and return absolute file paths. Limits: 65 minutes of render time for a
video, 30 for everything else, plus up to an hour in the queue. A call that runs past its limit does not fail: it
returns `pending: true` with the `job_id`, and the job keeps running and lands in the history. **Never submit it
again**; call `job_status(job_id, wait_s=600)` until it is done. For long renders (1080p with `quality="dfr"`: 5 s about
13 minutes, 6 s with a start image about 25) use `generate_video(..., wait=False)` right away. `progress` counts
sampling passes, not time, so estimate from the [run times](#run-times).

## Workflow

1. `health`: is everything running, is a model of the needed kind active?
2. If one is missing: `list_models(kind=...)` → `download_model` → `set_active_model`. **Don't guess**: `list_models`
   shows size, memory needs and license. Downloads are several GB, so ask the user first.
3. Generate. For video and 3D, tell the user up front how long it will take.
4. `copy_asset` into the target project, or pass the path straight on (for a mesh in Unity:
   `Unity_ImportExternalModel`).

## Recommended settings at a glance

The short version of everything below. The web interface shows the same per tab under **Recommended settings**; keep
both in step when a new finding comes in.

| Task | Recommended | Why (measured) |
|---|---|---|
| Final image, text in the image | `qwen-image-2512-nvfp4`, 50 steps, whole English sentences, text in quotation marks | lettering letter-perfect; rope handles through drilled holes where Lightning laid them on the wood |
| Edit an image, keep a character | `flux3-klein-nvfp4` with `reference_asset_ids`; say what changes and what stays | only the handles changed, the rest stayed; 13–30 s |
| Exact construction, counts or gaze with FLUX 3 | `upsample_prompt=False` with a full prompt in whole sentences | a second fishing line in 4 of 6 images with the upsampler, in 0 of 2 without |
| Photographic look | `krea2-turbo-nvfp4`, state the framing ("medium shot from the waist up, his whole head inside the frame") | without it the head was cut off in 3 of 3 images, with it in 0 of 2; ~20 s |
| Poster, sign, graphic with text, free to sell | `moss-image-sft-int8` (Apache-2.0), 50 steps; describe the finished image, text in quotation marks with position and typeface | letter-perfect in every test; ~51 s |
| Best result without settings | leave size, length and quality empty: `features.recommended` fills them (Qwen-Image-2512 1328², FLUX 3 1440², Krea 2 and MOSS-Image 1408², LTX-2.5 1920 × 1088 for 5 s with `quality="dfr"`, Stable Audio 3 60 s) | Qwen native: finer detail at double the time; LTX-2.5 DFR keeps faces and fabric sharp (5 s: 786 instead of 241 s) |
| Size | standing figure portrait (832 × 1216, Qwen 1056 × 1584), vehicle landscape (`features.sizes`) | in a square, figures lose their feet more often |
| Choosing | `batch_size=4`, compare at full resolution | one model load instead of four; anatomy errors are a failure rate |
| Video | LTX-2.5, one present-tense paragraph of 4–8 sentences, loud sound sources named | sounds described as soft came out at −41 to −52 LUFS |
| Long video render | `generate_video(wait=False)`, then `job_status(job_id, wait_s=600)` | 1080p DFR: 5 s ~13 min; a blocking call returns `pending`, never resubmit |
| Fixed framing | "Static camera, a locked-off medium shot; the framing stays exactly as in the first frame."; if it must hold, an end image too | "stays still" pushed in to an extreme close-up; the prompt alone pushed in 3 of 3 times |
| Loop or end image | only with a still camera, and only if the background may stand still | water and smoke stood as still as the shore, even when the prompt asked them to move |
| Moving background (water, smoke, wind) | only a start image, describe the motion | water and smoke kept moving; the camera of a medium-wide side view stayed put in 14 of 18 clips |
| Two clips without a seam | `chain_asset_id=<clip 1>` (or `extend_asset_id` for one file, or a `chain` marker in the Studio), joined with a 25-frame crossfade | the last 25 frames carry the motion over; at a hard cut the frame step stood out 1.9–2.5×, with the chain at most 1.6× |
| A person who should stay still | a short prompt (4–8 sentences), the stillness in one positive sentence ("sits perfectly still like a statue …"), the small reaction named exactly; rewrite instead of appending | 8 instead of 14 sentences: 38–49 % less motion with the same seeds |
| A small reaction (a start, a glance) | small and physical, say what does not move; avoid "fright", "flinch", "jerk" | "flinches briefly … jerk back" looked like a sneeze |
| A recognizable person in video | start image with FLUX 3 from a frontal, sharp reference, face 250 px or more, few extras, an end image or `loop=True`, no extending; most faithful: the real photo outpainted to the video size | face similarity 0.80–1.0 over 5 s with start = end image, 0.29–0.44 with the start image only |
| Video from several shots | Studio: one scene per shot, `chain` marker where shots must join, conform, export `youtube-1080p` | the chained clip went on with the same knight in the same pose |
| Zoom on a clip | `clip.update` with `anchor` [x, y] on the subject, then `clip.key` at the start (1.0) and the end (e.g. 1.5) | the focus point stayed within 0.5 px in the export |
| Quality through editing | leave `master` on (default); YouTube 1080p at 24 Mbit/s | export from the lossless copy 42.3 dB instead of 37.7 from the MP4 |
| MiniMax H3 (only with a separate license in the EU, UK, South Korea and USA; never publish its results) | the preselection: turbo LoRA 8 steps v1.1 + `sparse_attention="sol-attn"` + `int8_attention=True`; describe the pace of every movement | 9.4 s at 1344 × 576 in 6.6–6.9 instead of 37 min; it moves about half as much as LTX-2.5 |
| Sound effects / music | Stable Audio Open / Stable Audio 3 Medium | describe the sound for effects; music as one sentence with BPM, up to 5 minutes, no vocals |
| 3D source image | one object, plain background, no floor, no cast shadow; `project_front=True` for lettering | floor and shadow become a plate; lettering became a distorted relief |
| Old photo | `restore_image` with `repair_mode="auto"` (default), `batch_size=2`, known colors in `notes` | auto chose right on 20 of 21 test photos; color hints cut the color error by 40 % |

## Run times

Measured on an RTX 5060 Ti 16 GB; the first job after a start costs another 15–30 s for loading.

| Task | Model | Time |
|---|---|---|
| Image 1024², 50 steps / 1328² native | Qwen-Image-2512 NVFP4 | ~98 s / ~197 s |
| Image 1024², 8 steps (draft) | Qwen-Image-2512 Lightning | ~17 s |
| Image 1024², new / known prompt; four images; editing with a reference | FLUX 3 Klein NVFP4 | ~30 s / 13–16 s; ~37 s; ~45 s |
| Image 1024² / 1408²; with a style template | Krea 2 Turbo NVFP4 | ~20 s / ~37 s; 41–48 s |
| Image 1 MP, 50 steps | MOSS-Image INT8 | ~51 s (first expansion ~11 s extra) |
| Sound effect 6 s / music 60 s / 300 s | Stable Audio Open / Stable Audio 3 | ~12 s / 9–12 s / ~64 s |
| Video with sound 1280 × 704, 5 s; with a start image | LTX-2.5 NVFP4 | ~93 s; ~109 s |
| Start and end image 5 s / loop 4 s, 1280 × 704 | LTX-2.5 NVFP4 | ~154 s / ~125 s |
| Video 1920 × 1088, 5 s, standard / DFR | LTX-2.5 NVFP4 | ~251 s / ~786 s |
| 1920 × 832 from a start image, DFR 6 s / 5 s / extend by 3 s | LTX-2.5 NVFP4 | ~305–326 s / ~242 s / ~146–150 s |
| 1920 × 832, DFR 8 s (exceeds 16 GB, avoid) | LTX-2.5 NVFP4 | 20 to over 60 min |
| Video to a given sound, 20 s, 1024 × 576 | LTX-2.5 NVFP4 | ~302 s |
| Mesh from an image | TripoSG | ~60 s warm, ~180 s cold |
| Restore a photo, 2 variants at 2 MP / with colorizing | FLUX 3 Klein NVFP4 | ~150 s / ~200 s |
| Sharpen 1024² → 2048² | SeedVR2 7B NVFP4 | ~6 s |
| Studio export, 5 s 1080p from the lossless copy | NVENC 24 Mbit/s | ~4 s |

## Images

### Model choice: the four recommended models

- **Qwen-Image-2512, `qwen-image-2512-nvfp4`** (50 steps, cfg 4, Apache-2.0): first choice for **final assets**,
  **text in the image** and **structural details**. Lettering comes out letter-perfect, and rope handles pass through
  drilled holes, where the Lightning version (`qwen-image-2512-lightning`, drafts only) laid them on the wood.
  `negative_prompt` works; left empty, the server inserts Qwen's recommended one. Its native sizes (1328², 1056 × 1584,
  1584 × 1056 …) give finer detail at twice the time.
- **FLUX 3 Image Klein, `flux3-klein-nvfp4`** (16 steps, cfg 1): when working with **reference images**: edit an image,
  keep a character consistent over several images, combine up to ten images, place things with bounding boxes. A
  bundled upsampler first expands every prompt into a full description and returns it as `caption`; whatever the prompt
  leaves open, it invents (a greatcoat worn as a cape, lace-up shoes instead of boots), and without a style it plans a
  photo. `negative_prompt` has no effect. **License:** commercial use only below US$5 million revenue, every image
  reviewed before publishing (see [Licenses](#licenses)). The Base version brought no visible gain.
- **Krea 2 Turbo, `krea2-turbo-nvfp4`** (8 steps, cfg 1, ~20 s): **photographic images with little AI look**, natural
  hands and faces, letter-perfect lettering. **Name the framing**, otherwise it moves what the prompt stresses into
  view: a fisherman with "weathered hands" lost his head at the top of the frame in 3 of 3 images. No upsampler of its
  own, so `expand_prompt` first. With the optional style LoRA it takes one or two images in `reference_asset_ids` as a
  style template (describe only the content; with two, the first one wins; `features.missing.style_reference` says if
  the LoRA is missing). **License:** commercial use only below US$1 million revenue.
- **MOSS-Image, `moss-image-sft-int8`** (50 steps, cfg 3, ~51 s, Apache-2.0): **text and layout** (posters, signs,
  graphics) with no revenue limit. It expands short prompts itself (`caption`, `upsample_prompt=False` switches it off),
  and a JSON with "summary" and "items" as the prompt sets the layout. Text letter-perfect in every test. Text to image
  only: no references, no mask; an existing character came out as a different person.

On RTX 20/30/40 use the INT8 versions (`…-int8`); `list_models` marks what suits the detected card as `recommended` and
explains other formats in `gpu_note`. NVFP4 needs PyTorch cu130 in the ComfyUI venv; with cu128 it is three to five
times slower. What a model can do is machine-readable in `list_models(kind="image", detailed=True)` under `features`.
More models (SDXL, Pony, Illustrious …) come from **Models → Search Hugging Face**; ask before downloading. Details and
all test findings: [MODELS.md](MODELS.md).

### Prompts for Qwen, FLUX 3, Krea 2 and MOSS-Image

These read the prompt with a language model, not with CLIP, so the CLIP rules (77 tokens, `(word:1.3)`) do not apply.

- **Whole English sentences:** medium and style first, then the subject with material, color and condition, then light
  and background. Long prompts are fine.
- **State the construction**, otherwise it gets invented: "rope handles pass through drilled holes in the side boards".
- **Text in quotation marks**, verbatim, with position and kind: `black stenciled letters on the front read "MUNITION 7,92"`.
- **No weighting brackets:** noise for these encoders, and the FLUX 3 upsampler copies them into its text.
- **FLUX 3:** style first, then subject, count, arrangement, construction, text; specify clothing and fastenings. If the
  image is wrong, read `caption` first and extend the prompt instead of rerolling. **For exact construction, counts and
  gaze use `upsample_prompt=False`** with a full prompt: the upsampler added a second fishing line in 4 of 6 images,
  without it 0 of 2. Positive wording matters there too: a float that "floats on the water" hung in mid-air in 4 of 4,
  "lies on the surface … half under water, with small rings" lay on the water in 4 of 4.
- **FLUX 3 references:** "the first image", "the second image"; to edit, say what changes and what stays.
- **FLUX 3 boxes:** append `[{"id": "crate_1", "bbox": [top, left, bottom, right], "desc": "…"}]` on a 0–1000 grid. Do
  not cite the ids in the text as `<crate_1>`: then the text counts as finished and skips the upsampler.
- **Krea 2:** like Qwen, plus the framing ("medium shot from the waist up", "full body, both boots inside the frame").
- **MOSS-Image:** describe what the finished image looks like; text with position, size and typeface, line breaks set
  yourself.

### Scenes and people

- **Never count, arrange.** "exactly one truck" has no effect. Instead: "the front tanker truck rolls through the
  barrier. Behind it a line of separate tanker trucks waits nose to tail, each with its own dark cab." Without
  "separate" and "each with its own", similar objects merge.
- **Style and light first**, said positively ("oil on canvas with visible brush strokes" instead of "not a photo"); one
  sentence per image element; **name the time of day**, otherwise it becomes dusk. With about eight conditions no model
  hits everything: make several candidates.
- **People need pixels.** As soon as people are recognizable, use `hires=True` (against missing feet and broken
  faces); with FLUX 3 choose a larger size instead, it has no second pass.
- **Name people's origin** as region plus features ("two Central European dock workers with pale northern European
  features"); without it the faces vary.
- **Style bans in the negative prompt flatten the picture** ("sketch, loose brushwork …"); keep it to about ten terms.

### Size

The format decides more than the prompt: a standing figure in a square loses its feet more often.

| Size | Use for |
|---|---|
| **832 × 1216** (Qwen 1056 × 1584) | standing figures |
| **1024 × 1024** (Qwen 1328 × 1328) | objects, icons |
| **1216 × 832** (Qwen 1584 × 1056) | vehicles, buildings in side view |
| 1344 × 768 | wide scenes |
| 512 × 512 | sprites, tiles |

FLUX 3 works up to 2048 × 2048 (multiples of 16); older models (Chroma, SDXL) become incoherent above 1 MP.
`features.sizes` lists the sizes per model. Name exactly one view ("strict side view"), use common type names ("Panzer
IV") to call up a learned shape, plan hands out of the picture instead of describing them, and use `batch_size=4`
instead of four calls.

### Quality switches

| Parameter | When |
|---|---|
| Qwen's native sizes | final assets with Qwen; more detail at twice the time |
| `hires=True` | hands, faces, fine technical detail (not FLUX 3); about 50 % more time |
| `reference_asset_ids` | FLUX 3: change an almost-right image in a targeted way |
| `image_asset_id` + `denoise` | other models: refine an almost-right image (0.3 gentle, 0.5 clear) |
| `mask_asset_id` + `denoise=1.0` | regenerate one area (white = new). Qwen replaced lettering cleanly; FLUX 3 fills through a greyed reference (`features.mask == "reference"`): good for removing and adding, to change something already there edit with a reference instead |
| `outpaint=[left, top, right, bottom]` | extend an image: models with `features.outpaint == "reference"` (FLUX 3) first; the mask way of Qwen gave a hard edge |
| `batch_size=4` | whenever you want to choose |

**What doesn't help:** "bad anatomy, extra fingers" in the negative prompt, raising CFG (burnt colors, not better
shapes), the `karras` or `exponential` scheduler (more deformations), more steps than the model default (detail, not
structure).

**Historical vehicles:** no model knows the silhouette of a Panzer IV; two seeds gave two different invented vehicles.
More seeds do not help here, tell the user. Accuracy would need a template and a ControlNet, and none is built in;
reference images fix the content, not the shape.

**Other models in the catalog:** Chroma1-HD fp8 (painterly, atmospheric, unfiltered, `steps=16`), LongCat-Image (when
an action must be visible), FLUX.1 schnell (fast previews, no negative prompt), SDXL and Juggernaut (largest LoRA
ecosystem), Illustrious and NoobAI (Danbooru tags, not sentences), Pony V6 XL (`score_9, score_8_up, …`). For these CLIP
models weighting such as `(full body:1.2)` works, and prompts should stay under about 55 words.

## Old photos: restore, colorize, sharpen

`restore_image(image_path=...)` (or `image_asset_id`; REST `POST /api/image/restore`, the **Restore** tab) runs up to
three steps, each switchable:

1. **`repair`: remove damage.** FLUX 3 gets the photo as a reference with a fixed restore instruction (your `notes` are
   appended), works at 2 MP (at 1 MP a soldier in a group photo got a stranger's face) and the result is aligned with
   the photo.
   - `repair_mode="thorough"`: the whole picture from FLUX; cracks, crack networks, water stains and fading go, film
     grain partly stays.
   - `repair_mode="gentle"`: only the detected damage (dust, spots, scratches, tears, light leaks, writing) goes into
     the photo at full resolution; sharpness and faces stay the photo's.
   - **Choose by the kind of damage, not its amount:** overall aging → thorough, separate damage on an otherwise good
     photo → gentle. `repair_mode="auto"` (default) does this: the upsampler answers "Are there water stains, rings
     left by water, or crack networks (craquelure) in this photograph?" (about 2.5 s); "no" → gentle, anything else →
     thorough. It chose right on 20 of 21 test photos; `meta.repair.auto` holds the choice.
   - Faces vary with the seed: keep `batch_size=2` and compare at full resolution. Small marks such as a hyphen can
     disappear: check lettering. To keep a sepia tone, don't write "black and white" into `notes`.
2. **`colorize`:** FLUX 3 colorizes, but only the color is laid onto the photo's brightness, so faces stay. Known colors
   in `notes`, in English ("his suit is dark brown, her dress is dark red with white dots"), cut the color error by
   40 %; without them colors are guesses (a brown suit came out blue). Color can bleed across edges of equal brightness.
3. **`sharpen` with `scale` 1–4:** SeedVR2 7B sharpens and enlarges, at most 16 MP (1024² → 2048² in 6 s); at strong
   enlargement it invents fine detail.

What FLUX 3 computes falls under the FLUX Kommunity License; SeedVR2 output is free (Apache-2.0).

## Audio

- **Stable Audio Open** → sound effects and ambience, up to 47 s (short effects 3–8 s). Describe the **sound**:
  "heavy metal sword clash, single impact, bright metallic ring, dry studio recording", "footsteps on gravel, close
  mic, no music".
- **Stable Audio 3 Medium** → instrumental music up to 300 s (music 30–120 s), no vocals. **One sentence:** genre with
  the main instruments, layers and percussion, the mood, then "BPM: 100."; `expand_prompt(target="music_sa3")` writes
  this form, and NVAI-open appends the length.

```
"A dark orchestral war theme with low brass, taiko drums and a wordless male choir,
 slowly building tension over a steady march rhythm. BPM: 90."
```

Every audio output goes through NVAI-open's limiter (−1 dBFS; video sound −2.5 dBFS). There is no model for songs with
vocals. Normalize before putting a track into a video (−14 LUFS); the Studio export does that itself.

## Video

### LTX-2.5, the first choice

`ltx25-distilled-nvfp4` (RTX 50) or `ltx25-distilled-int8` (RTX 20/30/40): picture and sound in one pass, MP4.
LTX-2 Community License, free below US$10 million revenue. `fps=24`, sizes from `features.sizes` (multiples of 64;
1280 × 704 is 720p, 1920 × 1088 is 1080p), frames 8n+1 (97 = 4 s, 121 = 5 s, up to 481 = 20 s). Prefer the higher
quality and say what it costs: 1920 × 1088 takes about 2.7 times as long as 1280 × 704, `quality="dfr"` about three
times. On 16 GB keep a clip at 1920 × 832 to 6 s at most (8 s with DFR ran 20 to over 60 minutes); build longer scenes
from parts.

**Writing the prompt** (Lightricks' order): one paragraph in the present tense, 4–8 sentences: shot → setting and
light → the action with verbs → people by physical cues instead of emotion words → camera → sound. Spoken lines in
quotation marks with the voice; pacing and pauses written out ("For the first two seconds nothing happens: …"; timing
words are followed only roughly). **Name loud sound sources explicitly**: sounds described as soft came out at −41 to
−52 LUFS, speech and a forge at −14 to −18. Keep it short and rewrite instead of appending corrections: 8 instead of 14
sentences gave 38–49 % less motion where a person should stay still. Say stillness in one positive sentence ("sits
perfectly still like a statue … through everything that happens") and don't name what must not happen, not even
negated: "does not reach into the bucket" was ignored twice.

`generate_video` options:

- `image_asset_id`: start image. Describe only the motion; match its aspect ratio.
- `end_image_asset_id`: last frame; `loop=True` uses the start image as the end image too (only with a still camera,
  otherwise the last frames fall apart).
- `quality="dfr"`: detail over the whole clip (edge sharpness of a face after 2 s 625 instead of 211), about three
  times the time; needs the detail IC-LoRA (gated); not with an end image or a loop. `temporal_upscale=True` gives
  48 fps.
- `auto_duration=True`: the model picks the length from the action. `audio_asset_id`: the picture follows a given sound
  (at most 20 s), which stays unchanged in the MP4.
- `motion_speed` below 1: real slow motion only with the Slow Motion LoRA (spray fell over 5 s instead of 1.5 s).
- Several shots in one clip: write each cut out in prose ("A hard cut transitions to a close-up of …", 2–4 shots);
  `expand_prompt(target="video_multishot")` writes that form.
- `chain_asset_id=<clip 1>`: the new clip starts with the last 25 frames of clip 1, carried in latent space, and
  continues its motion; it is `frames` + 24 frames long. Lay it 25 frames before the end of clip 1 and crossfade over
  those frames (the Studio's `edit.conform` does that). `extend_asset_id` does the same and joins both into one file.
  Not with a start or end image, a loop, a given sound, 48 fps or automatic length (then the last frame becomes the
  start image). At a hard cut the frame step stood out 1.9–2.5×, with the chain at most 1.6×, like ordinary motion.
- `crf` (default 12, about 16 Mbit/s at 1080p; the softness comes from the model, not the encoder).

If an optional file is missing (DFR, 48 fps, automatic length), `features.missing` names the Hugging Face page.

**End image and loop freeze the background.** Whatever is pixel for pixel the same in start and end image stands
still in between: water and smoke changed as little as the static shore (0.3–2 of 255 per half second), even with a
sentence asking them to move. With only a start image they kept moving (water 1–9, smoke 1–12), and the camera of a
medium-wide side view stayed put in 14 of 18 clips. So: end image or loop to hold a face or the framing, only a start
image for a moving background. Say this before rendering.

**Prompt traps:** "shouts" gives grimaces ("says firmly in a rough, deep voice" is calmer); a gesture that "may rise
out of the frame" makes the camera follow it; "The camera holds a medium close-up" pushed in to an extreme close-up,
while "Static camera, a locked-off medium shot; the framing stays exactly as in the first frame." held; "proud, calm
expression" became a grin ("stern, determined expression and does not smile" did not); a raised fist filling the frame
lost a finger; thin props that cross people (rifles, flag poles) morph into each other, so keep them apart in the start
image and don't move them all at once.

**LoRAs** (`features.recommended_for` contains `ltx25`, `features.strength` is the suggested strength): Cinemagraph only
with a start image and `loop=True` (6 % of the picture moved, the face stood still); Slow Motion as above; Fantasy Anime
and Fantasy Painterly change the look clearly; Paper Cut-Out only at 1.5; Claymation and Transition hardly. Lightricks'
other IC-LoRAs need a source video, which NVAI-open does not take.

### Person from a photo

Turn a portrait into a video: the face from the photo in a role, saying a line (web interface: Video tab → "Person
from a photo").

1. **Start image with FLUX 3:** the photo as `reference_asset_ids=[photo]`, prompt "Cinematic film still. The person
   from the first image, with exactly the same face, eyes, nose, mouth and hair color: <role>. Medium shot from the
   waist up, the face clearly visible, free space above the head.", in the video size with `batch_size=4` (1280 × 704:
   95–98 s). Crop the photo to head and shoulders and name the clothing. FLUX makes faces a little slimmer and younger,
   so compare the four with the photo at full resolution.
2. **Video with LTX-2.5** from the chosen image: motion only, the line in quotation marks with the voice, then the
   sounds; to keep the face, `loop=True` (still camera) or the same image as `end_image_asset_id`.

With a real photo, the photo itself is the most faithful start image: outpaint it to the video size with FLUX 3, the
face stays pixel for pixel. The voice is generated, never the person's real one.

### Keeping faces, voices and characters over several clips

Measured with one character over many comedy clips and an explainer video:

1. **Face reference:** frontal, looking into the lens, nothing in front of it, sharpened with SeedVR2 (`restore_image`
   with only `sharpen`). A reference with a sideways glance came back from FLUX 3 as a crooked stare; with a good one,
   face and eyes were right in 4 of 4 images. Start images with FLUX 3; MOSS-Image draws a different person, and the
   Ingredients IC-LoRA (a reference sheet instead of a start image) never gave a recognizable face.
2. **Face size:** 250 px or more (medium shot or closer), few extras far in the back. At 100–200 px eyes blurred and
   running extras melted; LTX works on 32-px cells, so a 30-px eye is a single cell.
3. **Hold camera and face with an end image** (edited from the start image with FLUX 3) or `loop=True`: similarity
   0.80–1.0 over 5 s, against 0.29–0.44 with the start image only. "Static camera" alone still pushed in (3 of 3).
4. **Extending** used to see only the last frame, and a different man appeared; since 0.5.17 it carries the last
   second, but face fidelity over long pieces is not measured. Build longer scenes from parts with clean start and end
   images; each seam still jumps slightly (the first frame is 2.4–6.4/255 off its start image).
5. **Nothing in front of the face:** an explosion right behind the person, flying dirt or darkness gave a different
   face a second later. A teacup in front of the mouth did no harm.
6. **Voice:** LTX-2.5 draws the voice anew for every clip from the description, the visible face and the seed. Let
   people speak only with their face in the picture, keep the voice description word for word the same, and make 2–3
   variants per line for the user to listen to (Claude cannot hear). To **lock a voice**, cut an approved line out of
   its take, upload it as WAV and pass it as `audio_asset_id`: four clips carried exactly her line and LTX moved the
   lips to it. The clip length then comes from the sound.
7. **Start image without a face** (from behind): when the person turns round, LTX invents a face. Keep them turned
   away, or give an end image with the face.
8. **Pin an action down through the end image:** the start image with only the result filled in by a mask (FLUX 3:
   a fish in the bucket, everything else pixel for pixel) as `end_image_asset_id`. The whole action played out, one
   fish with one tail, the hands stayed on the rod. If the pose changes, edit with references instead (result image
   first, face second). Simplify props (a rod without a reel).
9. **Small reactions:** describe them small and physical and say what does not move. "flinches briefly, his head and
   shoulders jerk back a little" looked like a sneeze; "his upper body twitches back" came with a lean forward first.
10. **Name what must be seen** with size and place (the incoming shell), say where the person does not look, and pin
    down counts ("exactly one fish … there is no second fish").

### MiniMax H3

> **License:** The MiniMax H3 Community License excludes the EU, the UK, South Korea and the USA, private use and the
> generated videos included (sections I.3, I.5, V.4). Without a separate license from MiniMax
> (<https://platform.minimax.io/h3-license>) it must not be used there, and nothing made with it may be published,
> stills and screenshots included. The web interface marks the model and every result in red until the user ticks "I
> have obtained a permission" under Models; `list_models` shows `license_badge` and `license_confirmed`. Tell the user
> before using it unless `license_confirmed` is true. Anyone offering third parties a tool for generating with it must
> prevent prohibited content (section V.5); NVAI-open filters nothing.

- **Versions:** `minimax-h3-fl2va-int8` (text and an optional start image), `minimax-h3-ref2va-int8` (up to 9
  `reference_asset_ids`, in the prompt `<Picture 1>`, `<Picture 2>` … in their order), `minimax-h3-fasth3-8step-int8`
  (fixed 8 steps). Picture and stereo sound, 24 fps, frames on the 17k+5 grid (124 = 5.2 s, up to 362 = 15 s), up to
  768p.
- **Preselection:** turbo LoRA 8 steps v1.1, `sparse_attention="sol-attn"` and `int8_attention=True`: 9.4 s at
  1344 × 576 in 6.6–6.9 instead of 37 minutes. `recommended=True` (default) fills what a call leaves open,
  `recommended=False` takes the call literally. Fastest: turbo 4 + sol-attn (4.5–4.8 min).
- **Slow motion:** it moves about half as much as LTX-2.5; describe the pace of every movement ("bursts in a split
  second", "at full real-time speed"), which made an explosion 30–55 % stronger. FastH3 moves almost like LTX.
- **Prompt:** full English sentences, style first, then the scene, several shots as a timeline (`[0s-2s] Shot 1: …`)
  with the camera, the sound last (dialogue in quotation marks with the speaker).
- Test series and hardware advice: [MODELS.md](MODELS.md#minimax-h3-since-0518).

### Other video models

- **Wan:** describe the motion explicitly, or little happens. 832 × 480 is the cheap default, frames 4n+1, output WEBM.
  Wan 2.1 T2V 1.3B for fast tries, Wan 2.2 TI2V 5B for quality (13 GB VRAM). **Wan 2.2 I2V A14B** (image to video,
  loads two experts one after the other): on 16 GB 5 s at 1280 × 560 took 55 minutes, with the 4-step LoRA 6.5 minutes,
  and both came out in slow motion; for people in a scene LTX-2.5 stays the better choice.
- Text-to-video models take no start image; an image-to-video model without `image_asset_id` fails with a clear
  message.
- Tested and not built in: **Kandinsky 6** (Pro 928–966 s per 5 s against 114 s with LTX-2.5, Lite fell apart, its
  sound parts are non-commercial and its video VAE is not licensed in the EU), the **Restore** IC-LoRA (did not bring a
  changed face back and added artifacts) and **Ingredients** (see above). HunyuanVideo 1.5 is not an option in the EU.

## Studio: whole videos from scenes

A Studio project has two timelines. The **composition** holds scenes (prompt, model, length) on four lanes, `video`
(video clips or still images), `voice`, `music` and `sfx`, plus markers that say what goes where. The **edit** holds
the real clips on the tracks V1, V2 (above V1) … and A1, A2 …, with in and out points, speed, gain, transitions and
zoom. The web interface uses the same commands as the MCP tools, so the user sees every change live and can undo it.
User guide: [STUDIO.md](STUDIO.md). NVAI-open for Mac has the same Studio, REST interface (`/api/studio/*`) and project
format; there video scenes use the Mac's video model and a chain starts from the last frame.

| Tool | Purpose |
|---|---|
| `studio_projects` | Projects, newest first |
| `studio_create(name, width, height, fps)` | New project, returned in compact form (times in seconds) |
| `studio_get(project_id, conform_plan=False)` | Scenes with status (`empty`, `waiting`, `running`, `done`, `error`) and take, markers, tracks, clips, the project `folder`; `conform_plan=True` adds what `edit.conform` would do |
| `studio_command(project_id, command, params)` | One command: `scene.add/update/delete/take`, `marker.add/update/delete`, `edit.conform`, `clip.add/move/trim/razor/delete/update/key`, `track.add/delete/update`, `batch`, `project.update` (the tool description lists the parameters) |
| `studio_generate(project_id, scene_ids=None, wait=True)` | Generates every scene without a take, or the given ones; `wait` blocks for at most an hour. For several DFR scenes use `wait=False` and poll `studio_get` |
| `studio_export(project_id, preset)` | Renders the edit, returns the file path |

Workflow:

1. `studio_create`, then one `scene.add` per shot, each video prompt written like for `generate_video`. Add
   `marker.add` with `kind="chain"` where two shots must join seamlessly and `kind="transition"` for dissolves.
2. Tell the user how long it will take, then `studio_generate`. Look at three frames of every video take at full
   resolution; for a scene that missed, set a new seed with `scene.update` (`params.seed`) and run
   `studio_generate(scene_ids=[…])`. The old take stays, `scene.take` switches back.
3. `edit.conform`, cuts with `clip.razor`, `clip.trim`, `clip.delete`, then `studio_export`. If the user has already
   worked on the edit, read `studio_get(conform_plan=True)` first and pass `scenes` and `overwrite` instead of
   conforming blindly. Many users cut themselves: after new takes, conform them into the edit and let the user decide
   before exporting a final version.
4. Markers of kind `ai` that are not done are tasks the user left for you: carry them out, then `marker.update` with
   `done=true`.

To stop a run, `POST /api/studio/projects/{id}/cancel` (feature `studio_cancel`) cancels every queued and running job of
the project's scenes and releases waiting chained scenes; finished takes stay. Never cancel a run the user started
without asking.

**Times** are seconds with the suffix `_s` (`start_s`, `duration_s`, `at_s`, `in_s`) or ticks (254 016 000 000 per
second). Set clip starts in ticks when they follow other clips: rounded seconds (4.7917 + 4.5) left a 0.03 ms gap and a
black frame in the export.

**Editing commands:**

- **Speed:** `clip.update` with `speed` (0.1 to 10); the sound keeps its pitch. If a slower clip would run into the
  next one, pass `overlap`: `clamp`, `ripple` or `overwrite`.
- **Transitions:** `transition={kind, duration_s}` with `dissolve`, `dip_black`, `dip_white` or `wipe`; a `transition`
  marker acts on the clip that starts at it. The outgoing clip runs on past its out point, so a clean dissolve needs
  about 0.5 s of its own material there; otherwise its last frame freezes.
- **Zoom:** `clip.update` with `scale` (0.1 to 8), `anchor` [x, y] (the focus point that stays in place) and
  `scale_keys`, or `clip.key` with `id`, `at_s` and `value` for one keyframe (`delete`, `clear`). Below 1.0 the clip
  becomes a picture in picture over the track below. Keyframes live in media time, so a cut or a speed change keeps
  them on the same moment.
- **Tracks:** `track.add` (`video` on top, `audio` at the bottom), `track.delete` (not V1/A1), `track.update` with
  `hidden` and `muted`; both apply to the export.
- **Groups:** `clip.move` with `moves=[{id, start_s, track}]`, and `batch` with `commands=[{command, params}]` as one
  undo step.

**Project folders:** every project has its own folder `assets/Studio/<name>` (`folder` in `studio_get`). Takes,
exports, last frames and uploads land there; `list_assets(folder="Studio/<name>")` lists them. Images, videos, sound
and restored photos made for a project outside its scenes go straight into its folder with `project_id` on
`generate_image`, `generate_video`, `generate_audio` and `restore_image`. `clear_history` leaves project folders alone.

**How a scene becomes a job:**

- **Video:** LTX-2.5 with frames = 8n+1 from the length, 1280 × 704 (projects below 1900 px) or 1920 × 1088 with "Best
  quality (DFR)" when the detail IC-LoRA is installed (project setting `video_quality`, per scene `params.quality`).
  `params` pass on seed, size, LoRAs, start and end image and `audio_asset_id`.
- **Still image:** about 1 MP in the project's aspect ratio (a title card with Qwen: `params` 1664 × 928).
- **Music and sound:** the scene's length, up to 300 s.
- **Voice:** no text-to-speech yet; add a recorded audio file as a take (`scene.take` with `asset_id`).
- **Chain:** a video scene with `chain_from`, or starting at a `chain` marker, continues the earlier scene: with LTX-2.5
  it takes over the last 25 frames, and `edit.conform` lays the take exactly over them with a dissolve, so the edit
  keeps the length of the scenes. Otherwise the last frame becomes the start image. If the source is generated in the
  same run, the chained scene waits (`waiting`) and starts as soon as its source is done.
- **Order in the GPU queue:** sound, still images, videos grouped by model, chained scenes last, so LTX-2.5 is not
  unloaded in between.

**Export presets:** `youtube-1080p` (H.264, 24 Mbit/s), `youtube-2160p` (H.265, 40 Mbit/s), `shorts-1080x1920` (H.264,
10 Mbit/s), `av1-1080p`, `project` (H.264 in the project's size), `master` (FFV1 in MKV, pixel-exact) and `prores`
(ProRes 4444 in MOV). The encoder is found by trying one frame: NVENC, AMF, Quick Sync, then software. The sound of all
clips is mixed, set to −14 LUFS and limited at −2.5 dBFS; the export runs in its own queue next to generating. Clips
within 5 % of the project's aspect ratio fill the frame (LTX's 1920 × 1088 loses 8 rows), others are letterboxed.

Be honest about the cost: 10 minutes made only of LTX-2.5 clips are 120 clips of 5 s, about 3 hours at 720p and 8.5
hours at 1080p. Still images with music and voice are much cheaper.

### Recipe: an explainer video with a presenter

1. **Start images first.** LTX-2.5 invents a new face in every text-to-video scene, so a person who appears more than
   once needs start images: `flux3-klein-nvfp4` in the video size with `batch_size=4`, style first. For more shots of
   the same person pass the chosen image as `reference_asset_ids` ("The woman from the first image, with exactly the
   same face, glasses, curly hair and dark green hoodie, …"): 4 of 4 kept face, clothing and room. Give each scene its
   image as `params.image_asset_id`; the scene prompt then only describes motion, speech and sound.
2. **Speech:** the line in quotation marks with the voice, plus "Static camera, a locked-off shot; the framing stays
   exactly as in the first frame." Plan about 2 words per second (15 words ran past the end of a 6 s shot, 11 fit),
   give the person something to do after the line, leave gestures out (even "a single quick wave" lasted 2.5 s), use
   commas rather than exclamation marks (after "Hi!" a 0.6 s pause), and show product names on screen instead of
   having them spoken. You cannot hear the take: check that speech is there and ask the user to listen.
3. **Quality per scene:** `params.quality="dfr"` for shots with a face and speech, `"standard"` for the rest (a 6 s DFR
   shot from a start image at 1920 × 1088 took 25 minutes, a 4 s standard shot 4).
4. **Title cards** are image scenes with `qwen-image-2512-nvfp4` at 1664 × 928 and the text in quotation marks ("…
   nothing else written anywhere"): 3 of 3 letter-perfect.
5. **Music** is a scene on the `music` lane; after `edit.conform` it lies on A2, lower it under speech with `gain_db`
   (here −9 dB).
6. **Vertical for Shorts:** a new project at 1080 × 1920, start images from FLUX 3 at 1088 × 1920 with the landscape
   start image (layout) and the presenter (face) as references, spoken clips with the approved line as
   `audio_asset_id`, export `shorts-1080x1920`.

### Recipe: short comedy scenes with one character

1. **Keep the format of the original:** for a 1920 × 802 film, scenes at 1920 × 832 (the export crops 15 rows top and
   bottom). DFR at 1920 × 832 took 305–326 s for 6 s, while 1920 × 1088 took 1248–1519 s.
2. **The face from the original** (frontal, looking into the lens, sharpened with SeedVR2) as the FLUX 3 reference,
   clothing written out, medium shot or closer, four variants per scene.
3. **The joke has to be in the start image.** A soldier holding a washing line in the air is not funny; FLUX tied the
   line to the gun barrel in 0 of 4 images. When a connection is missing, edit the best variant (it as the first
   reference, the face as the second, "Change only …, keep … exactly as in the first image"): 4 of 4 right.
4. **Write the timing into the prompt:** "For the first two seconds nothing happens: …, then the tank suddenly fires"
   gave 1.3 s of calm build-up; without it the shot came after 0.2 s. Deadpan: "his face completely still, his eyes
   fixed on the distance".
5. **Cutting it into an original film:** check it for pulldown first (a 30p file holding 24p repeats every fifth frame)
   and set the in points so that every original frame appears exactly once. Match the loudness: new scenes came out
   about 9 dB louder than the original and got `gain_db` −9; measure quiet scenes in their new place.

## Lossless copy of every video

Every video model also writes the frames losslessly (FFV1 in MKV, sound as float PCM taken before the limiter). The MP4
stays the file for previews, browsers and Unity; the copy is the source for editing. `generate_video` returns it in
`lossless_files`, `master=False` skips it. It costs about 32 MB per second at 1080p. The Studio's YouTube export from
the copy reached 42.3 instead of 37.7 dB PSNR at the same file size, and a chain start image from it is pixel-exact.

## Image to 3D

Two stages: an image, then `image_to_3d` on it. **There is no text prompt for the mesh stage**: the image fully
determines the mesh. `text_to_3d(prompt)` does both and adds what the reconstruction needs:

```
text_to_3d("a weathered stone gargoyle", faces=60000)
```

**What's in the image ends up in the mesh:** floor, table edges and cast shadows become plates under the object,
gradients and fog become floating strands, two objects fuse. A base that belongs to the object (a statue's pedestal)
is fine. So the image prompt includes "the complete object including any base that belongs to it, plain flat
background, no cast shadow, not standing on a floor or table", and the negative prompt "cast shadow, floor, ground
plane, table surface, environment" (not "pedestal" or "base"). With TRELLIS.2, `background_mode="birefnet"` (default)
gives clean edges and `clean_specks=True` (default) removes loose fragments; TripoSG always cuts out by flood fill from
the borders, so give it a plain background. `project_front=True` puts the source image onto the front so lettering
stays readable.

| | TripoSG | TRELLIS.2-4B |
|---|---|---|
| Output | geometry only | geometry + PBR textures (2048²) |
| Time | ~60 s warm | ~75 s warm, ~160 s with loading |
| VRAM | ~10 GB | ~14 GB |
| Faces | `faces=-1` full (~200k), otherwise 10,000–40,000 | `faces` (default 100,000), `texture_size` |
| Comes with | the setup | an installation from source |

Neither mesh is guaranteed to be watertight, and both need retopology before going into a game; tell the user.

## VRAM: one card, one model

16 GB holds one model; the server runs GPU jobs one after another. Before a model over 13 GB (Wan 2.2 I2V A14B) call
`POST /api/backend/free` ("Free VRAM" in the web interface). `image_to_3d` frees ComfyUI's memory before the mesh, so
make all images first and then all meshes. Downloads run in their own queue.

**Several graphics cards:** without a choice, everything runs on the strongest card. Splitting brought no gain in our
test (an RTX 5060 Ti plus an RTX 4060 on a riser), and full load on both once made the second card drop off the bus,
so ask before running both. `GET/PUT /api/gpus` assigns a card per kind.

**AMD Radeon (experimental):** PyTorch with ROCm 10, falling back to 7.2.1. Do not use the `-nvfp4` ids there;
`list_models` marks the right versions as `recommended` (on a Radeon RX 9000 FP8 and bf16, on others INT8). 3D needs
NVIDIA.

## Licenses

Before assets go into a game that is sold. `list_models` returns `commercial_ok`. This is not legal advice; the license
text is authoritative.

- **FLUX Kommunity License** (FLUX 3 Image Klein): commercially only below US$5 million annual revenue including
  affiliated companies; a content filter **or** a review of every image before publishing; AI labeling where the law
  requires it; BFL can terminate by notice; the images must not train another image model. No EU exclusion.
- **Krea 2 Community License:** commercially only below US$1 million revenue, a filter or a review of every image, AI
  labeling where required, Krea can terminate with 30 days' notice.
- **Stability Community License** (Stable Audio Open, Stable Audio 3): commercially up to US$1 million revenue.
- **LTX-2 Community License** (LTX-2.5): free below US$10 million revenue.
- **MiniMax H3:** not allowed in the EU, UK, South Korea and USA without a separate license; never publish results.
- **Hunyuan3D:** not licensed in the EU, UK and South Korea; use TripoSG (MIT).
- Unproblematic: Qwen-Image-2512, MOSS-Image, SDXL, FLUX schnell, Wan, Chroma, TripoSG, TRELLIS.2, SeedVR2.

Without the FLUX or Krea conditions, use Qwen-Image-2512 (Apache-2.0). `list_models` also returns `content`
(`uncensored`, `partial`, `censored`, null) with its source; NVAI-open itself filters nothing. When in doubt, point the
user to the license instead of generating silently.

## Reading errors correctly

- **`clip input is invalid: None`** → the checkpoint has no text encoder; the model is missing files (`list_models`
  shows which). Don't tinker with the prompt.
- **`No <kind> model installed`** → `list_models(kind=...)`, then suggest a download.
- **`… is an image-to-video model — please provide a start image`** → pass `image_asset_id` or choose a text-to-video
  model.
- **Timeout while starting the backend** → `GET /api/backend/log` (or `?worker=triposg`) shows the real reason.
- **Job stays `queued`** → another GPU job is running. Downloads don't block.
- **`No access to … the repo is gated`** → the license is not accepted yet, or with another account than the token's.
  Retrying does not help: point the user to [HUGGINGFACE.md](HUGGINGFACE.md).

## Getting assets into the game

```
copy_asset(asset_id, "C:/path/to/UnityProject/Assets/Generated/")
```

Unity imports it on its own; for meshes `Unity_ImportExternalModel` with the path from `image_to_3d` is more direct. A
sensible place: `Assets/Generated/Textures|Audio|Video|Meshes/`. Don't mix generated assets into existing folders
without asking.
