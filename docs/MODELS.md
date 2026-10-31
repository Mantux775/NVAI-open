# Image models in NVAI-open: Qwen-Image-2512, FLUX 3 Image Klein, Krea 2 and MOSS-Image

*Deutsch: [de/MODELLE.md](de/MODELLE.md)*

A reference for projects that generate images through NVAI-open. It applies to Claude Code with
the `nvai` MCP server as well as to your own programs using the REST API. It describes the four
image models NVAI-open recommends: what they can do, how to address them, how long they take and
where they fail. All four side by side, with the same prompts and seeds: [MODEL_COMPARISON.md](MODEL_COMPARISON.md).

As of October 18, 2026 (Krea 2: October 24, MOSS-Image: October 25). Measured on an RTX 5060 Ti 16 GB (ComfyUI 0.41.3, PyTorch 2.11 cu130).
All times and findings were measured there. Statements that come from the vendor are marked as
such ("according to BFL").

---

## 1. At a glance

| | **Qwen-Image-2512** | **FLUX 3 Image Klein** | **Krea 2 Turbo** | **MOSS-Image** |
|---|---|---|---|---|
| Model ID | `qwen-image-2512-nvfp4` | `flux3-klein-nvfp4` | `krea2-turbo-nvfp4` | `moss-image-sft-int8` |
| Vendor | Alibaba (Qwen) | Black Forest Labs, October 2026 | Krea.ai, June 2026 | OpenMOSS, October 2026 |
| Size | 20B parameters, NVFP4 | 5.6B parameters, NVFP4 | 12B parameters, NVFP4 | 5B parameters, INT8 |
| Text encoder | Qwen2.5-VL-7B | Qwen3-VL-4B, plus a prompt upsampler (Qwen3.5-9B) | Qwen3-VL-4B (the same file as FLUX 3) | Qwen3.5-9B (W4A8), expands short prompts itself |
| Steps / CFG | 50 / 4.0 | 16 / 1 (distilled) | 8 / 1 (distilled) | 50 / 3 |
| Negative prompt | works; empty = default from Qwen's model card | has **no** effect | has **no** effect | works; empty = the recommendation from ComfyUI's template |
| Reference images | — | up to 10 | — | — |
| Placement by box | — | yes | — | by JSON layout ("summary", "items"; according to OpenMOSS) |
| Text in the image | letter-perfect | 3 of 3 error-free in testing | letter-perfect in the test | letter-perfect in every test |
| Time per 1024² image | ~100 s | ~30 s for a new prompt, 13–16 s for a known one | ~20 s | ~51 s (25 steps ~28 s), plus ~11 s for the expansion the first time |
| License | **Apache-2.0** | **FLUX Kommunity License** — revenue cap, review obligation | **Krea 2 Community License** — below US$1M revenue, review obligation | **Apache-2.0** |
| Strengths | final assets, structural details, text | editing, consistent characters, layout, speed | photographic look, natural hands and faces, speed | text and layout, posters and graphics, free to sell |

## 2. Which model for what

| Task | Model |
|---|---|
| Final asset without a template: object, figure, icon, scene | **Qwen** |
| Text, lettering, signs | **Qwen** or **MOSS-Image** (about half the time, both Apache-2.0) |
| Poster, graphic, layout with a lot of text | **MOSS-Image** (~51 s): describe the finished image, text in quotation marks with position and typeface |
| Construction must be right (fastenings, hinges, handles) | **Qwen** |
| Photographic image with little AI look, natural hands and faces | **Krea 2** (~20 s), name the framing; license only below US$1M revenue |
| Change an existing image in a targeted way: replace a part, color, material | **FLUX 3** with the image as a reference |
| The same character or object across several images | **FLUX 3** with a reference image |
| Combine subjects from several images | **FLUX 3** with several references |
| Several objects at fixed positions | **FLUX 3** with bounding boxes |
| Quick drafts | FLUX 3 (13–16 s), Krea 2 (~20 s) or Qwen Lightning (`qwen-image-2512-lightning`, ~17 s) |
| Historically accurate vehicles (Panzer IV, Sd.Kfz. 251 …) | **none** — see section 9 |
| Only a few words of prompt, model without its own upsampler | first **✨ Expand prompt** (`expand_prompt`), see section 5 |
| Restore or colorize an old photo | **Restore** tab (`restore_image`): FLUX 3 removes damage and colorizes, SeedVR2 sharpens, see "New in 0.5.11" |
| Trying out Qwen-Image 2.1 (`qwen-image-2.1-int8`) | **non-commercial only** (Qwen Research License); editing looked overprocessed in the test |

Without a `model_id`, NVAI-open uses the active image model.

### Tested, not included (October 2026)

- **Kandinsky 6** (Kandinsky Lab, MIT; picture and sound in one pass, 5 s at 864 × 480, full HD only with an
  extra super-resolution model): Pro distilled met the expectations but took 928–966 s per 5 s clip on a
  16 GB card (LTX-2.5 with the same start image: 114 s at 1280 × 704), Lite fell apart, and super-resolution
  would have taken about 1.5 h for 5 s. Its audio parts are non-commercial, and its video VAE (Tencent) is not
  licensed in the EU. Details: [CLAUDE_CODE.md](CLAUDE_CODE.md#kandinsky-6-tested-27-october-2026-not-built-in)
- **LTX-2.5 IC-LoRAs Restore and Ingredients** (Lightricks): Restore did not bring back a face that had
  changed and added artifacts; Ingredients (a reference sheet instead of a start image) did not keep a real
  person recognizable in any test. For a recognizable person the start image carries the face, held with an
  end image or "Loop" ([PHOTO_TO_VIDEO.md](PHOTO_TO_VIDEO.md#tips-from-our-tests)); the background then stands
  still.

### MiniMax H3 (since 0.5.18)

> **⚠️ Not allowed in the EU, the UK, South Korea or the USA without a separate license from MiniMax.** The MiniMax H3
> Community License excludes these territories (sections I.3 and I.5) and prohibits any use of the weights and their
> outputs there, private use included (section V.4). **Videos and images from it must not be published**, stills and
> screenshots included; that is why there is no picture here. License request:
> <https://platform.minimax.io/h3-license>. The interface marks the model and every result in red ("Do not publish")
> until the box "I have obtained a permission" is ticked under "Models". Anyone who offers third parties a tool for
> generating with MiniMax must prevent prohibited content under the license (section V.5); NVAI-open filters nothing.

Three versions, all with picture and stereo sound in one pass, 24 fps, 5 to 15 s, up to 768p: **start image** (FL2VA,
text and optionally a start image), **reference** (Ref2VA, up to 9 reference images, in the prompt `<Picture 1>`,
`<Picture 2>` …) and **FastH3** (fixed 8 steps, hardly any slow motion). Plus the turbo LoRAs by lightx2v (4 or 8
instead of 20 steps).

**Preselected** is the fastest measured way without an image jump: turbo LoRA 8 steps v1.1, sol-attn and INT8
attention (start image 6.9 min, reference 6.6 min instead of 37). The Generate page sets it when you switch to the
model, Studio and MCP get it from the server as long as the job says nothing else (`recommended`). On cards without
sol-attn (older than RTX 30) or without INT8 attention (older than RTX 20) and on AMD the switch drops out; without the
LoRA it renders with 20 steps. NVAI-open does not set up Veda: if the node pack Veda-on-ComfyUI is in ComfyUI's
`custom_nodes`, it can be chosen.

First test on an RTX 5060 Ti 16 GB: the same scene as with LTX-2.5 (9.4 s: an impact, an explosion, a fish falls into
a bucket), once from the start image (FL2VA), once from two reference images and the description (Ref2VA). MiniMax
followed the description more closely than LTX-2.5, and the face from the reference images stayed the same through
the whole clip; the fish's flight path was not right yet.

| | MiniMax H3 (INT8, 20 steps) | LTX-2.5 (NVFP4, DFR) |
|---|---|---|
| Result | 9.4 s at 1344 × 576 (the open weights stop at 768p) | 9 s at 1920 × 832, two clips joined by the latent chain |
| Render time, RTX 5060 Ti 16 GB | 37.3 min from the start image, 37.1 min from reference images (about 107 s per step) | about 7 min (clip 1 260 s, clip 2 162–177 s) |
| Download | 39.1 GB (start image version with turbo LoRA), reference version another 19.5 GB, about 59 GB together | 37.5 GB |
| Memory while rendering | 14.9 GB of graphics memory, free system memory never below 31.8 GB (of 64 GB) | not compared |

Without speed-ups MiniMax took a good five times as long for just under half the pixels.

- **Size:** The full model has 33B parameters. Built in is the pruned version (about 20B going by the file size) in
  INT8 at 19.5 GB, plus the text encoder Qwen3-VL-32B in NVFP4 (14.6 GB), the video and audio VAEs (3.2 GB) and the
  8-step turbo LoRA (1.8 GB).
- **NVFP4:** Neither MiniMax nor Comfy-Org offers the transformer in NVFP4. Comfy-Org recommends `int8_convrot` with
  PyTorch cu130, which is how it runs here; only the text encoder is NVFP4. Third-party conversions exist on Hugging
  Face, for example `Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot` and `MATLOWAI/minimax-h3-nvfp4`: the pruned version at
  11.7 instead of 19.5 GB, for FL2VA and Ref2VA. Whether it is faster and looks as good is not measured. The same
  license applies to them.
- **What the test showed:** From the start image the pose and the face stayed stable, but the fish appeared in the
  bucket instead of flying. From the reference images the fish flew, the sound followed the brief almost exactly
  (silence, whistle, explosion, tail slap), and the face stayed the same through the whole clip; the arrangement
  differed, and the background of one reference moved into the picture.

**Faster with turbo LoRAs and sparse attention** (test series on the same card, the same scene, seed 42, 1344 × 576,
9.4 s; time = whole job including loading; motion = mean frame change per quarter second):

<!-- messreihe -->
| Run | Version | Speed-up | Steps | Render time | Sound (dBFS RMS) |
|---|---|---|---|---|---|
| Run 1 | start image | no LoRA | 20 | 37.3 min | wind from the start (−14 dBFS), explosion −4.8 at 2.5 s, no tail slap of its own |
| Run 2 | reference | no LoRA | 20 | 37.1 min | quiet start (−38), whistle, explosion −5.8, tail slap at 6.5 s (−18.8), then silence |
| Test 1 | start image | turbo 8 v1.0 (544p, shift 12/3, res_multistep like ComfyUI's template) | 8 | 15.8 min (2.4× faster) | loud from the start (−6 to −9), explosion −5.2, small peak at 6.75 s (+4 dB) |
| Test 2 | reference | turbo 8 v1.1 768p (shift 12/3, euler, "match") | 8 | 16.8 min (2.2× faster) | sampling 15:01 (113 s/step); quiet start (−37), whistle and explosion 1.25–2.5 s (−6.0), impact 3.75 s (−23), silence from 5.5 s, tail slap 6.5 s (−20.2), then silence |
| Test 3 | reference | like test 2 + sol-attn (tau 1.3 from 20 %) | 8 | 8.3 min (4.5× faster) | sampling 7:15 (dense 113, sparse ~34 s/step); start −30, explosion 1.25–2.5 s (−6.2), impact 3.5 s, silence from 5.5 s, tail slap 6.75 s (−19.9) |
| Test 4 | start image | turbo 8 v1.1 768p (shift 6/3, euler) | 8 | 15.8 min (2.4× faster) | sampling 14:25; loud from the start (−7 to −9), explosion 2.25–3 s (−7.2), decay to −40, small peak 7.0 s (+3.5 dB) |
| Test 5 | start image | like test 4 + sol-attn | 8 | 8.2 min (4.5× faster) | sampling 7:22; loud from the start (−7), explosion 2.25–2.5 s (−7.7), tail slap peak 6.75–7.0 s (+5 dB) |
| Test 6 | reference | turbo 4 v1.0 768p (shift 12/3, euler, "match") | 4 | 8.5 min (4.4× faster) | sampling 7:25 (112 s/step); quiet start (−42), explosion 1.25–2.0 s (−6.7), silence from 5 s, tail slap 6.5 s (−21.6), then silence |
| Test 7 | start image | turbo 4 v1.2 768p (shift 6/3, euler) | 4 | 8.7 min (4.3× faster) | sampling 6:53 (103 s/step; first run after a restart, cold start in the total); loud from the start (−7), explosion 1.25–2.5 s (−5.6), tail slap peak 6.75 s (+6 dB) |
| Test 8 | reference | like test 6 + sol-attn | 4 | 4.8 min (7.7× faster) | sampling 2:39 (dense 112, sparse ~16 s/step); quiet start (−40), explosion 1.25–2.0 s (−6.4), noise 5.75–6.5 s (−29), tail slap 6.75 s (−22.3), then silence |
| Test 9 | start image | like test 7 + sol-attn | 4 | 4.5 min (8.3× faster) | sampling 2:29; loud from the start (−8), explosion from 1.25 s (−5.3), peaks 6.5 and 7.0 s (−27), noise 7.75–8.25 s |
| Test 10 | reference | turbo 8 v1.0 768p (shift 12/3, euler, "match") | 8 | 15.7 min (2.4× faster) | sampling 14:21 (109 s/step; model switch in the total); start −33, explosion 1.25–2.5 s (−6.0), silence from 5 s, tail slap 6.5 s (−20.5), then silence |
| Test 11 | reference | like test 3 + INT8 attention | 8 | 6.6 min (5.6× faster) | sampling 5:38; start −27, explosion 1.25–2.5 s (−6.4), impact 3.5 s, silence from 5.5 s, tail slap 6.75 s (−20.7), then silence |
| Test 12 | reference | like test 2 + INT8 attention | 8 | 8.3 min (4.5× faster) | sampling 7:09 (without INT8 15:01); quiet start (−39), explosion 1.25–2.5 s (−5.8), impact 3.75 s, silence from 5.5 s, tail slap 6.5 s (−19.9), then silence |
| Test 13 | reference | like test 3, sol-attn tau 1.5 | 8 | 8.2 min (4.5× faster) | sampling 7:08 (tau 1.3: 7:15); start −28, explosion 1.25–2.5 s (−6.0), impact 3.5 s, silence from 5.5 s, tail slap 6.75 s (−19.4), then silence |
| Test 14 | reference | like test 2 + Veda (32 tiles) | 8 | 6.7 min (5.5× faster) | sampling 5:15 (R2VA predictor; cold start and compile in the total); motion 1–4 s 2.34 instead of 1.78 (test 2), but image jump at 7.75 s (5.1); sound: silence (−49), explosion 1.25–2.0 s (−5.4), tail slap 6.5 s (−19.8), then silence |
| Test 15 | start image | FastH3 8 steps (VSA, shift 10/3, fixed) | 8 | 7.9 min (4.7× faster) | sampling 6:50 (loading the new checkpoint in the total); motion 1–4 s 4.21 (other MiniMax 1.8–2.8, LTX 5.1), explosion 8.7 at 2.5 s (LTX 7.5); sound loud from the start (−6), explosion 2.25–3.0 s (−3.6), tail slap 7.0 s (+20 dB), then silence |
| Test 16 | start image | like test 4 + Veda (32 tiles) | 8 | 6.1 min (6.1× faster) | sampling 5:05 (38 s/step, including the one-off Triton kernel compile); loud from the start (−11), explosion 1.25–2.25 s (−5.7), tail slap peak 6.75 s (+6 dB), then silence (−40); Veda: 28 % padding tiles at 1344 × 576; image jump at 7.75 s (13.2) |
| Test 17 | reference | like test 14 + INT8 attention | 8 | 6.3 min (5.9× faster) | sampling 5:13; motion and sound identical to test 14: next to Veda, INT8 has no effect |
| Test 18 | start image | like test 4 + INT8 attention | 8 | 8.0 min (4.7× faster) | sampling 6:46 (without INT8 14:25); loud from the start (−8), explosion 1.25–2.5 s (−6.3), tail slap peak 6.75 s (+5 dB) |
| Test 19 | start image | like test 9, prompt with tempo (real time, fast, energetic) | 4 | 4.6 min (8.1× faster) | sampling 2:29; motion 1–4 s 2.48 instead of 2.19 (test 9), explosion 6.6 instead of 4.3 (LTX 5.1/7.5); sound loud from the start, explosion 1.25 s (−4.3), tail slap 7.0 s (+11 dB) |
| Test 20 | start image | like test 16, prompt with tempo | 8 | 6.1 min (6.1× faster) | sampling 5:05; motion 1–4 s 2.80 instead of 2.75 (test 16); again an image jump at the end (9.0 s, 10.1); sound loud from the start, explosion 1.25 s (−4.8), tail slap 6.75–7.0 s (+9 dB) |
| Test 21 | reference | like test 8, prompt with tempo | 4 | 4.8 min (7.7× faster) | sampling 2:33; motion 1–4 s 1.78 instead of 1.76 (test 8), explosion 3.7 instead of 2.8; sound: louder start (−24 instead of −40), explosion 1.5 s (−6.7), tail slap 6.75 s (−26.6), then silence |
| Test 22 | reference | like test 14, prompt with tempo | 8 | 6.3 min (5.9× faster) | sampling 5:14; motion 1–4 s 2.41 (test 14: 2.34), image jump at 9.0 s (6.1); sound: start −34, explosion 1.25–2.0 s (−5.0), tail slap 6.5 s (−21.5), then silence |
| Test 23 | start image | like test 5 + INT8 attention (default candidate) | 8 | 6.9 min (5.4× faster) | sampling 5:21 (test 5 without INT8: 7:22); motion: explosion 2.25 s (4.43), tail slap 7.0–7.25 s (2.0–2.3); sound: explosion from 1.25 s (−5.6), tail slap 7.0 s (−29.0), then silence (−40) |
<!-- /messreihe -->

<!-- zusammenfassung -->
**Summary** (measured on an RTX 5060 Ti 16 GB with 64 GB of RAM; the same scene, 9.4 s at 1344 × 576, seed 42;
time = whole job including loading):

| Goal | Start image version | Reference version |
|---|---|---|
| Starting point | 20 steps: 37.3 min | 20 steps: 37.1 min |
| **Preselected:** fast, no image jump | turbo 8 v1.1 + sol-attn + INT8: **6.9 min** | turbo 8 v1.1 + sol-attn + INT8: **6.6 min** |
| Fastest | turbo 4 v1.2 + sol-attn: **4.5 min** | turbo 4 v1.0 + sol-attn: **4.8 min** |
| Little slow motion | FastH3 (fixed 8 steps): **7.9 min**, motion almost like LTX | – (FastH3 takes no references) |
| Not recommended | Veda at 1344 × 576 (image jump near the end) | Veda at 1344 × 576 (image jump near the end) |

- **Attention is the bottleneck, not memory.** sol-attn halves the render time (sampling 15:01 → 7:15), so does the INT8
  attention (→ 7:09), both together 5:38 (start image 5:21). tau 1.5 instead of 1.3 changes nothing (7:08). Next to Veda,
  INT8 has no effect at all (identical results). Veda is the fastest (5:05–5:15) but jumps near the end at this size (28 %
  of its tiles are padding; it is planned for 1344 × 768 or 1536 × 768).
- **Turbo LoRAs:** shift as lightx2v says (start image LoRAs at 768p 6/3, reference LoRAs 12/3), euler, simple; v1.0 and v1.1
  equally fast. With turbo the reference version still hits the silence and the tail slap; the start image version starts
  loud. Only one turbo LoRA is active at a time: it sets the steps and the shift.
- **Slow motion:** all files are 24 fps. MiniMax moves only about half as much as LTX-2.5 during the explosion (frame change
  1.8–2.8 against 5.1). Pace in the prompt makes the explosion stronger (+30–55 %), the rest barely. FastH3 reaches 4.2. 24 fps
  counts as the lower limit for smooth motion (cinema); 16 fps stutters; 30–60 fps only through in-between frames, MiniMax
  runs at a fixed 24.

**Advice for this hardware** (RTX 5060 Ti 16 GB, 64 GB RAM; measured):
- Everyday: the preselection, turbo 8 + sol-attn + INT8 (6.6–6.9 min). Drafts: turbo 4 + sol-attn (4.5–4.8 min). Lots of
  motion: FastH3 (7.9 min, start image only). Final version: 20 steps (37 min). Always describe the pace of every movement.
- 14.9 GB of graphics memory in use, the INT8 transformer (19.5 GB) is offloaded; free RAM stayed above 31.8 GB. Less than
  64 GB of RAM is tight with MiniMax.

**Advice for other hardware** (from sources, not measured):
- **RTX 50 with more graphics memory** (24–32 GB): the same ways. NVFP4 weights help little there too (RTX 5090: 175 instead of
  185 s, ai-muninn.com) because attention is the bottleneck. Veda at its planned sizes (1344 × 768, 5/10/14 s): 2.9 times as
  fast as without on an RTX 5070.
- **RTX 30/40** (sm80–sm89): sol-attn and INT8 attention run (comfy-kitchen: sol-attn from sm80, INT8 from sm75), NVAI-open
  preselects them. The INT8 weights (convrot) need PyTorch with cu130, otherwise fp8_scaled (Comfy-Org). Veda only
  experimental (triton-windows), no NVFP4.
- **RTX 20** (sm75): INT8 attention yes (preselected), sol-attn and Veda no.
- **8–12 GB of graphics memory:** by Veda's measurement H3 runs on an RTX 5070 with 12 GB (1344 × 768, 5.2 s, turbo 8: 342 s,
  with Veda 130 s). Render shorter and smaller (864 × 480), 64 GB of RAM.
- **AMD Radeon:** comfy-kitchen says sol-attn runs on RDNA3/4; in NVAI-open that is untested, so it offers neither sol-attn
  nor INT8 attention there. The turbo LoRA stays preselected.
- **Mac:** MiniMax is not built into NVAI-open for Mac.
<!-- /zusammenfassung -->

### New in 0.5.13

**Studio:** a full-screen editor for whole videos. Scenes with a prompt on lanes for picture, voice, music and sound,
markers that say what goes where (a chain marker starts a clip with the last frame of the one before it), an edit with
real cuts and dissolves, and an export with the graphics card's encoder at −14 LUFS. Claude Code drives it with six
`studio_*` tools. Step by step: [STUDIO.md](STUDIO.md).

**Lossless copy of every AI video:** next to the MP4, every video model also writes the frames losslessly (FFV1 in MKV,
sound as float PCM). The Studio exports and takes chain start images from it. Measured with LTX-2.5 at 1080p: the
copy needs about 32 MB per second (the MP4 2 MB); a YouTube export made from the MP4 reached 37.7 dB PSNR against the
original, made from the copy 42.3 dB at the same bitrate. "Lossless copy for editing" under "Generate → Video" turns it
off.

![The same detail: the original, a YouTube export from the MP4 and one from the lossless copy](images/lossless-export.jpg)

**YouTube 1080p at 24 Mbit/s** instead of 12: 42.8 instead of 42.3 dB; 40 Mbit/s gave 43.0 dB, and 4:2:0 color itself
caps at 43.9 dB. New export formats: a lossless master (MKV, FFV1) and ProRes 4444 (MOV); browsers cannot play either,
so both get an H.264 preview.

**ACE-Step removed:** its music was consistently poor in practice. Music now comes from Stable Audio 3 Medium
(instrumental, up to 5 minutes); no model sings for now.

### New in NVAI-open for Mac 0.5.0

**Video models by memory.** Under "Models" the Mac recommends one video model for its memory:

| Unified memory | Recommended | Sound | Status |
|---|---|---|---|
| below 16 GB | LTX-Video 2B | no | measured: 4 s at 768 × 512 in 174 s on an M1 with 8 GB |
| 16–23 GB | LTX-Video 13B, 4-bit | no | checked block by block, not run whole |
| 24–31 GB | LTX-Video 13B, 8-bit | no | checked block by block, not run whole |
| 32–63 GB | LTX-2.3 distilled, 4-bit | yes | built in, not run; macOS 26.3 |
| 64 GB and more | LTX-2.5 distilled, 8-bit | yes | built in, not run; macOS 26.3, gated |

- **LTX-Video 13B** runs in NVAI-open's own MLX port: the architecture of the 2B with 48 instead of 28 blocks of width
  4096. Lightricks' fp8 file (13.2 GB) is converted to 4 or 8 bits on download. Checked against ComfyUI on the first two
  blocks: float32 within 2.6e-6, 8-bit as close as bf16 (7.3e-3, bf16 6.8e-3), 4-bit 2.3e-2. NVAI-open's test Mac has
  8 GB, so the whole model was not run there: memory (about 10.5 GB in 4-bit, 17 GB in 8-bit) and times are estimates.
- **LTX-2.3 and LTX-2.5 with sound** come from [ltx-video-swift-mlx](https://github.com/VincentGourbin/ltx-video-swift-mlx)
  by Vincent Gourbin (MIT), built in as a local copy: picture and sound in one pass, from text or a start image. The
  downloads are large (about 46 and 70 GB); LTX-2.5 is gated (accept the license on Hugging Face, enter a token in the
  settings). Not run on the 8 GB test Mac.
- Below its minimum memory a model cannot be downloaded, neither in the app nor over REST.
- **In the [Studio](STUDIO.md#on-the-mac-nvai-open-for-mac-049)** video scenes use the model chosen under "Generate" >
  "Video" (at first the recommended one, once it is downloaded); with several installed, a scene picks its own in the
  properties.

Reports from Macs with more memory are welcome as an [issue](https://github.com/Mantux775/NVAI-open/issues): time,
memory, picture.

### New in NVAI-open for Mac 0.4.8

**Z-Image Turbo** (Tongyi-MAI, Apache-2.0) is the third image model of the Mac version next to FLUX.2 Klein and
Core ML: photographic images and lettering, text to image, 8 steps, no negative prompt. The download is 6.2 GB: the
4-bit build by mflux-community plus 0.28 GB of layers in bf16. mflux also quantizes the input and output layers, the
timestep and caption embeddings and the modulation to 4 bits, and on the Mac that gave orange, blurred images with a
16-pixel grid. NVAI-open fetches exactly these layers in bf16 from mlx-community/Z-Image-Turbo-bf16 (by byte range,
without the 12.3 GB repo). With the same seed the crate then came out as weathered wood with a rope handle and
letter-perfect lettering; at 1 MP the ropes passed through drilled holes.

| Measured on a Mac mini M1, 8 GB | |
|---|---|
| 512 × 512 | 101 s, peak 4.6 GB |
| 832 × 1216 (1 MP) | 399 s (eight steps of about 48 s, decoding 10 s), peak 5.4 GB |
| Largest image | 1 MP on 8 GB (the decoder works in overlapping tiles, no visible seams), 1536² otherwise |

**Video with LTX-Video 2B** (Lightricks, 0.9.8 distilled): text or a start image to video in eight steps, 24 frames
per second, no sound, in a "Video" task next to "Create image". NVAI-open runs it through its own MLX port, checked
against the reference implementation. The download is 9.0 GB (the transformer, decoder and encoder from Lightricks'
file, the T5-XXL text encoder in 4-bit); on disk it takes 8.1 GB, because the encoder is converted once into a
smaller form. License: LTX-Video Open Weights License, free below US$10M annual revenue; mark distributed videos as
AI-generated.

| Measured on a Mac mini M1, 8 GB | |
|---|---|
| 512 × 320, 2 s (49 frames) | 40 s, peak 5.4 GB |
| 768 × 512, 4 s (97 frames) | 174 s, peak 6.2 GB |
| 768 × 512, 2 s (49 frames) with a start image | 91 to 97 s (1 to 2 s of it for the image), peak 6.0 GB |

Picture and motion hold together (a torch with sparks and a camera push-in, a crate in the rain); lettering does not
come out.

**Start image:** the chosen picture becomes the first frame; it is center-cropped to the video size, and choosing a
portrait picture switches to the portrait size. In the prompt, describe the picture briefly, then the motion and the
camera. Measured with a wave on rocks and a painted campfire: the first frame matches the picture (PSNR 26.4 to
26.8 dB), and the motion starts from it without a jump. Lightricks also blurs the start image and
compresses it like a video frame (H.264, CRF 29). On the Mac the same compression (HEIC with the same deviation) made
the motion stutter in pairs of frames like a 12 fps video, so NVAI-open only crops and scales; the slight noise that
Lightricks adds to the start image in every step stays (12 % more motion with the wave, just as smooth). Downloaded
LTX-Video before 0.4.8? "Add start image" under "Models" fetches only the encoder (1.4 GB). End image, loop, sound and
LoRAs remain with LTX-2.5 in the Windows version.

**Finding more models:** the search under "Models" now has "Images" and "Videos". For images it finds the Core ML
pipelines NVAI-open can load (Stable Diffusion 1.5, 2 and XL) even when they are not among the 50 most downloaded
results for a word: "realistic" found none before, now 11. MLX image models appear with a note: FLUX.2 Klein and
Z-Image Turbo run as catalog models, other versions and families do not load. For videos it lists text-to-video and
image-to-video models with the same notes: LTX-Video 2B runs (catalog), LTX-2.3 and 2.5 need 32 GB of memory or
more, Wan and the others are not built in yet. LoRAs are not shown; the Mac does not load them from the search.

The footer now shows the version (NVAI-open 0.4.8).


### New in NVAI-open for Mac 0.4.7

NVAI-open for Mac now restores like the Windows version and adds LoRAs and audio, all natively on Apple Silicon
(MLX). Measured on a Mac mini M1 with 8 GB:

| What | How | Measured (M1, 8 GB) |
|---|---|---|
| Gentle restoring | keeps the photo at full resolution and only replaces the damage, same rules as on Windows | identical to the Windows code at equal size; 1.1 s for 1216 × 1600 |
| Automatic | Qwen3.5 4B (Apache-2.0, 3 GB) looks at the photo and decides with a calibrated threshold whether the damage covers the whole picture: then thorough, otherwise gentle | as expected on 20 of 21 test photos, about 20 s |
| Sharpen and enlarge | SeedVR2 3B (ByteDance, Apache-2.0, 4.7 GB) in 384 px tiles with blended seams and color matching per tile | 1024 × 738 → 2× in 9 min, 1600 × 1216 → 2× in 28 min |
| LoRAs | five Apache-2.0 LoRAs for FLUX.2 Klein: pixel art, sprite sheet, remove background, anime, consistent editing | first image after a change about 10 s longer |
| Music and sounds | Stable Audio 3 Medium (8-bit, 3.8 GB; Stability AI Community License), up to 60 s on 8 GB | 30 s of audio in 13 s, 60 s in 23 s |

Limits: FLUX.2 Klein 4B removes less damage than FLUX 3 on Windows (on a heavily aged test photo a crease and a torn
corner stayed). SeedVR2 3B smooths faces slightly more than the 7B on Windows, but keeps them natural; Real-ESRGAN
was faster but made old photos look waxy and was dropped. On 8 GB the models load one after another.

![The same face sharpened to twice the size: original, SeedVR2 7B on Windows, SeedVR2 3B on the Mac](images/mac-sharpen-seedvr2.jpg)

![FLUX.2 Klein on the Mac without and with the pixel art LoRA](images/mac-lora-pixelart.jpg)

### New in 0.5.11

**MOSS-Image** (`moss-image-sft-int8`, OpenMOSS) is the fourth recommended image model: text and layout in the image under Apache-2.0, so images can be sold without a revenue limit or review obligation. It expands short prompts into a full description with its own text encoder (Qwen3.5-9B), stored in `caption` afterwards (`upsample_prompt=False` switches that off); according to OpenMOSS a JSON with "summary" and "items" sets the layout. The default is OpenMOSS's setting with 50 steps and cfg 3. Measured with the same prompts and seeds: 51 s per 1 MP image, plus about 11 s for the expansion the first time; with the 25 steps of ComfyUI's template 28 s. Text came out letter-perfect in every image, the soldier stood in the frame with both boots, the fisherman kept his head in the frame. The crate's rope handles passed through drilled holes in three of three images with 50 steps, in two of three with 25. Text to image only (no reference images, no mask), not available on the Mac.

![MOSS-Image: a poster with lettering, a crate with 25 and with 50 steps](images/moss-image-en.jpg)

**Restore and colorize old photos** (`POST /api/image/restore`, MCP `restore_image`, the "Restore" tab, PhotoCraft add-on 0.4.6). Three steps, each one optional:

| Step | What happens | Measured (RTX 5060 Ti) |
|---|---|---|
| Remove damage | FLUX 3 removes scratches, dust, tears, stains and emulsion damage; the result is aligned with the photo. **Automatic** (default) lets FLUX 3's upsampler look at the photo first and asks whether it shows water stains or crack networks: yes → Thorough, no → Gentle (as expected on 20 of 21 test photos, about 2.5 s). **Thorough** takes the whole picture from FLUX: crack networks, fine scratches, water stains and fading go, faces can change slightly from variant to variant. **Gentle** only puts the damage it detects into the photo and keeps sharpness, detail and faces at full resolution (a 1911 portrait kept its face although FLUX had changed it in one of two variants). Choose by the kind of damage: overall aging (water stains, crack networks, grain, fading) → Thorough; separate damage on an otherwise good photo (dust, scratches, tears, light leaks) → Gentle, which on real glass plates and a 1945 photo with a light leak kept the sharpness where Thorough came out softer. Similarity to the undamaged original on test photos (brightness, quarter size, 1 = identical): heavy damage 0.601 untouched, 0.648 gentle, 0.689 thorough; light damage 0.921, 0.932 and 0.911, where gentle was closest and thorough drew faces in a group photo differently | 2 variants: 70 s for a photo up to 1 MP, 150 s at the 2 MP working size; a 3.5 MP photo with colorizing 4.6 min |
| Colorize | FLUX 3 colorizes, but only the color is taken over; brightness, detail and faces stay the photo's. FLUX alone was off by 5.4 L in brightness, the transfer by about 1 | about 40 s per variant |
| Color hints | Known colors in "Hints" ("her dress is red with white dots …") | color error ΔE 17.5 → 10.4 (−40 %) on a photo with known colors |
| Sharpen | SeedVR2 7B (ByteDance, Apache-2.0, new model kind "Upscale") sharpens, removes coarse grain (fine noise in calm areas stayed in the test) and enlarges up to 4× (at most 16 MP) | 1024 → 2048 in 6 s, 1200 × 864 → 3840 × 2770 in 18.5 s |

The working size for removing damage is 2 MP (at most the photo's size): at 1 MP a soldier in a group photo got a different face. Limits: small marks that FLUX leaves out (a hyphen in a caption) disappear in both modes, so check lettering; film grain partly stays with thorough; color can bleed across edges of equal brightness; SeedVR2 invents fine detail at strong enlargement. FLUX 3 output falls under the FLUX Kommunity License.

![An aged test photo, restored and colorized by NVAI-open, next to the color original it was aged from](images/restore-car.jpg)

![Face: original, FLUX 3 alone, NVAI-open with only the color taken over](images/restore-face.jpg)

![Grayscale, colorized, colorized with color hints, ground truth](images/colorize-hints.jpg)

### New in 0.5.10

| What | Measured |
|---|---|
| Krea 2 with a style template | With ostris' style LoRA (0.46 GB, Krea 2 license) Krea 2 takes one or two images as a style template: the way of painting, the colors and the light come from the image, the content from the prompt. A lighthouse with a watercolor or a woodcut template came out clearly in their style, in 41–48 instead of 24 s. With both templates 71 s, and the first one almost completely won. See section 6 |
| Front from the image (3D) | "Take the front from the image" puts the cut-out source image onto the faces of the mesh that point to the camera, so lettering and stickers stay readable. TripoSG builds painted letters only as a faint, garbled relief; with the projection "HAFEN" on a direction sign was readable. The projection itself takes under a second (the whole mesh 66 s). The direction comes from the silhouette (front +Z, overlap 0.93 against 0.68 for the back). Loose bits of the cutout such as floor remnants are dropped first; if no direction fits clearly, the front is +Z, the view TripoSG builds from the image. The rest of a TripoSG mesh gets colors from the image; a TRELLIS.2 mesh keeps its own texture there (not tested yet, TRELLIS.2 is not installed here). `project_front` in `image_to_3d` and `text_to_3d` |
| Extend a video | LTX-2.5 continues an existing video: its last frame becomes the start image, size and frame rate come from the video, and the new part is appended with its sound. 5 s + 4 s at 1920 × 1088 gave a 9.0 s video (217 frames) in 255 s, without a visible seam. `extend_asset_id` in `generate_video` |
| "Streams" instead of "too large" | Models larger than the graphics memory run anyway: ComfyUI streams parts from system memory at every step. On a normal connection that cost little (Krea 2 INT8 without FP4: 13.0 s with 8 GB, 12.2 s with 16 GB), so the model list no longer marks them red as "too large for this GPU" |
| "Download extras" | Optional files of an installed model (Krea's style LoRA, LTX-2.5's detail LoRA for DFR …) now have their own button under "Models"; before, the model had to be downloaded again |

![Templates made with FLUX 3, Krea 2 without and with a style template](images/krea2-style-reference.jpg)

![A direction sign from TripoSG: the source image, the plain mesh, with the front from the image, and its back](images/front-projection.jpg)

**Which format for which card.** Only RTX 50 computes NVFP4 in hardware, RTX 20/30/40 compute INT8. In
0.5.9 Krea 2 NVFP4 was faster than INT8 on an RTX 4060 with 8 GB, because only the NVFP4 version fits
into 8 GB. That card sits on a riser, though (PCIe 3.0 x4, 3.9 GB/s). To see whether this holds on a
normal connection, the RTX 5060 Ti (PCIe 4.0 x8, 15.8 GB/s) ran without its FP4 units, so ComfyUI took
the same path as on an RTX 40, once with its 16 GB and once with 8 GB (ComfyUI held back the rest with
`--reserve-vram`). The absolute times are those of the 5060 Ti, what counts is the comparison. First
image with loading / next image, 1024 × 1024:

| Card | Krea 2 NVFP4 | Krea 2 INT8 | Qwen-Image-2512 NVFP4 | Qwen-Image-2512 INT8 |
|---|---|---|---|---|
| without FP4, 16 GB, PCIe 4.0 x8 | 29.8 / 25.0 s | 17.5 / 12.2 s | 226.9 / 214.0 s | 127.2 / 118.6 s |
| without FP4, 8 GB, PCIe 4.0 x8 | 28.5 / 25.1 s | 17.1 / 13.0 s | 237.9 s | 158.9 s |
| RTX 4060, 8 GB, PCIe 3.0 x4 (riser) | 46 s | 193 / 82 s | 1095 s | 653 s |

INT8 was faster even where it did not fit into the graphics memory (Krea 2 INT8 is 13.5 GB). Only on
the slow riser was NVFP4 ahead, and only where it fit and INT8 did not. NVAI-open now recommends INT8 on
RTX 20/30/40, and NVFP4 only on a connection of up to 4 GB/s when only the NVFP4 version fits
(`recommended` and `gpu_note` in `list_models`; with several cards, "Models → Graphics cards" shows the
connection of each card).

### New in 0.5.9

Video quality, measured on an RTX 5060 Ti with LTX-2.5 (1920 × 1088 unless stated otherwise):

| What | Measured |
|---|---|
| Best quality (DFR) | The default once Lightricks' detail LoRA is installed (accept its license on Hugging Face). ComfyUI's template inserts the start image at a quarter of the size, which made the whole video soft at 1080p; NVAI-open now uses the full image. Same seed: faces and fabric stay sharp over the whole clip (edge sharpness of the face after 2 s: 625 instead of 211), at about three times the time (5 s: 786 instead of 241 s). Not with an end image or a loop |
| Cinemagraph LoRA | Only works together with "Loop", which the web interface now switches on with it. A king in front of flickering torches, 4 s at 1280 × 704: with the loop 6 % of the picture moved and the face stood still; a loop without the LoRA 28 %; without a loop 82–84 % (also at strength 1.2), because the camera pushed in |
| Slow Motion LoRA | Tested with Lightricks' settings (a wave against rocks, 1920 × 1088, 5 s, slow motion 0.2): the spray fell over the whole 5 s instead of about 1.5 s at real time, with sharp droplets. Without the LoRA the spray stood almost still as a milky veil. At 1280 × 704 and 0.25 the effect was weaker |
| 48 fps | DFR with `temporal_upscale` keeps the sharpness of 24 fps (even and odd frames alike), at 294 instead of 118 s for 4 s at 1280 × 704 |
| 1080p first | The size list starts with 1920 × 1088 and says that it takes about 2.7 times as long (5 s in 251 s instead of 93 s at 1280 × 704) |
| Higher bitrate | MP4s are saved at CRF 12 instead of ComfyUI's 18: with the same seed 16.0 instead of 7.3 Mbit/s, 10 instead of 4.5 MB for 5 s. Fine detail barely changes, the softness comes from the model. `crf` per request |
| Face after a zoom out | An end image made with FLUX 3 (same references) keeps the face. Without one, the face of the king in the last frame (about 80 px wide) was soft and distorted; with one, the last frame matches the end image. 7 s took 648 instead of 509 s |
| Wider end image | Asked for a "wider shot", FLUX 3 kept the framing. Outpainting the end image (`outpaint=[320, 184, 320, 184]`, 1920 × 1088 → 2560 × 1456) gives a zoom out: the person ends at 75 % of the size |

![The face after 2 s at full resolution: DFR in 0.5.8, the standard path and DFR in 0.5.9](images/dfr-before-after.jpg)

Prompt traps seen in a scene with a speaking person and a crowd: "shouts" gives grimaces ("says
firmly in a rough, deep voice" is calmer). A gesture that "may rise out of the frame" makes the
camera follow it. "The camera holds a medium close-up" became a push-in to an extreme close-up;
"Static camera, a locked-off medium shot; the framing stays exactly as in the first frame." held the
framing. "Proud, calm expression" became a grin; "stern, determined expression and does not smile"
did not. Thin props such as rifles and flag poles that cross people in the start image morph into
each other in the video, so keep them apart in the start image and do not move them all at once.

**Krea 2 Turbo** (`krea2-turbo-nvfp4`) is the third recommended image model: the most photographic of the three, about 20 s per image, license only below US$1 million revenue. Comparison and prompt tips in section 6.

![Explorer in full body, same prompt and seed: Qwen-Image-2512, FLUX 3 and Krea 2 Turbo](images/compare-krea2.jpg)

Qwen-Image-2512 now also comes in INT8 for RTX 20/30/40 (`qwen-image-2512-int8`, see section 4): on an
RTX 4060 with 8 GB 653 instead of 1095 s with NVFP4. Krea 2 on the same card was faster with NVFP4 (46
instead of 82 s): only the NVFP4 version fits into its 8 GB, and the card sits on a slow riser
connection. On a normal connection INT8 is faster (see New in 0.5.10).
In the history, a click on a prompt shows it in full.

### New in 0.5.8

LTX-2.5 (`ltx25-distilled-nvfp4`) is now the recommended video model, with all of its ways. Measured
on an RTX 5060 Ti at 24 fps with sound; graphics memory is almost full and ComfyUI offloads.

| Way | Parameter | Measured |
|---|---|---|
| Text to video | — | 5 s at 1280 × 704 in 93 s (first run with loading 122 s); 1920 × 1088 in 251 s |
| Start image | `image_asset_id` | 5 s at 1280 × 704 in 109 s |
| Start and end image | `end_image_asset_id` | 5 s in 154 s; first and last frame match the two images. Whatever is the same in both stands still in between: water and smoke moved as little as the shore, even with a sentence asking them to move (before and after the event mostly as little as in a loop, 0.3–2 out of 255 per half second; the same scene with only a start image: water 1–9, smoke 1–12) |
| Loop | `loop=True` | 4 s in 125 s; first and last frame differ by 3.6/255 on average (12–44 without a loop). Only with a still camera: with a camera move the last frames fell apart. Water and smoke stand still, as with an end image |
| Automatic length | `auto_duration=True` | a door that opens slowly: 3 s, in 72 s |
| Given sound | `audio_asset_id` | 20 s of brass band → a 19.7 s clip at 1024 × 576 in 302 s, the sound unchanged |
| Several shots | `expand_prompt(target="video_multishot")` | 8 s in 170 s: two shots with a clean cut, the same lighthouse keeper in both |
| DFR, slow motion | `quality="dfr"`, `motion_speed` | not tested yet: they need LoRAs from Lightricks whose license has to be accepted on Hugging Face |

Describe sounds as loud as they should be: speech and a forge came out at −14 to −18 LUFS, a campfire
that "crackles softly" and a quiet village square at −41 to −52 LUFS, with or without a loop. The
generated sound now goes through the same limiter as all audio, for video at −2.5 dBFS because AAC
overshoots dense sound by up to 1.9 dB; it peaked at up to +1.7 dBTP before. New in the video tab:
"Person from a photo" lets FLUX 3 keep the face from a photo and create four start images in a role
you describe (95–98 s at 1280 × 704), which LTX-2.5 then brings to life; step by step in [PHOTO_TO_VIDEO.md](PHOTO_TO_VIDEO.md). Recommended LoRAs for LTX-2.5 and how they did: [INSTALL.md](INSTALL.md#loras-hugging-face-and-civitai).

### New in 0.5.7

| Model | Use for | Measured (RTX 5060 Ti) | License |
|---|---|---|---|
| Stable Audio 3 Medium (`stable-audio-3-medium`) | instrumental music, no vocals (a choir only without words); in NVAI-open up to 5 minutes | 60 s in 9–12 s (up to 9.7 GB graphics memory), 300 s in 64 s (16 GB card almost full) | Stability AI Community (below US$1M revenue) |

Write the prompt for Stable Audio 3 as one sentence: genre with the main instruments, layers and
percussion, the mood, then "BPM: 100.". NVAI-open appends "Length: N seconds" to match the duration.
"✨ Expand prompt" writes this form (`target="music_sa3"`).

ACE-Step 1.5 Turbo now runs like ComfyUI's template (8 steps, CFG 1, shift 3). Before, NVAI-open used
12 steps and CFG 2 without shift, which sounded harsh and compressed. Its license is MIT (the
catalog said Apache-2.0).

Every audio output now goes through NVAI-open's own limiter before it is saved (ceiling −1 dBFS, 5 ms
look-ahead, 80 ms release); ACE-Step is lowered by 3 dB first. Its raw output peaks up to +5.7
dBFS, and the MP3 encoder cut everything above 0 dB off hard. Measured with the same seed, true
peak of the MP3: industrial piece +2.3 → 0.0 dBTP, brass band +2.0 → +0.2 dBTP (with only the
3 dB: +1.3 and +0.9). What is left above −1 dB is MP3 overshoot.

### New in 0.5.3

| Model | Use for | Measured (RTX 5060 Ti) | License |
|---|---|---|---|
| LTX-2.3 (`ltx23-nvfp4`) | video with sound; the base most community LTX LoRAs are made for | 4 s at 1280 × 704 in 101 s, image to video 448 × 832 in 65 s | LTX-2 Community (below US$10M revenue) |
| Mochi 1 preview (`mochi-1-preview-fp8`) | text to video with smooth motion | 49 frames at 848 × 480 in 351 s | Apache-2.0 |
| Kandinsky 5.0 Video Lite, distilled (`kandinsky5-lite-t2v-distilled`) | small MIT video model, 5 s | 768 × 512 in about 300 s | MIT, VAE under Tencent's license |
| Kandinsky 5.0 Video Lite T2V / I2V | the same with 50 steps; I2V only in landscape 768 × 512 | about 26–27 minutes | MIT, VAE under Tencent's license |

LoRAs (also new in 0.5.3) work with SDXL, SD 1.5, Qwen-Image, Z-Image, FLUX.1/Chroma, Wan and
LTX-2/2.3; see [INSTALL.md](INSTALL.md#loras-hugging-face-and-civitai). Measured: a pixel-art LoRA
on Qwen-Image-2512 changed the style clearly at the same seed (168 s instead of 102 s); an orbit
LoRA pair on Wan 2.2 I2V A14B turned a slight turn into a full camera orbit.

### New in 0.5.2

| Model | Use for | Measured (RTX 5060 Ti) | License |
|---|---|---|---|
| Boogu-Image 0.1 Turbo (`boogu-image-turbo-nvfp4`) | fast drafts, 4 steps | 832 × 1216 in ~10 s | Apache-2.0 |
| Boogu-Image 0.1 Base (`boogu-image-nvfp4`) | full quality, negative prompt works | 832 × 1216 in ~66 s | Apache-2.0 |
| Boogu-Image 0.1 Edit (`boogu-image-edit-nvfp4`) | change an image by instruction; in the test only the hat changed | ~147 s | Apache-2.0 |
| HiDream-O1-Image Dev (`hidream-o1-dev-fp8`) | large images, trained at ~4 MP | 1728 × 2304 in ~41 s | MIT |
| HiDream-O1-Image (`hidream-o1-fp8`) | the same with 40 steps and negative prompt | ~142 s | MIT |
| LTX-2.5 (`ltx25-distilled-nvfp4`) | video with sound, text or start image | 4 s at 1280 × 704 in ~72 s | LTX-2 Community (below US$10M revenue) |

### Censored or uncensored

Every image and video model in the list carries a label: *uncensored*, *partly censored*,
*censored* or *filtering unknown*. The tooltip names the evidence and the source (model card,
technical report). NVAI-open itself filters nothing. The same information is in `GET /api/models`
(`content`, `content_note`, `content_source`).

| Label | Models (as of October 2026) |
|---|---|
| uncensored | Chroma1-HD, Pony Diffusion V6 XL, NoobAI-XL, Illustrious XL |
| partly censored | SDXL, Z-Image, Wan 2.1 / 2.2 |
| censored | Qwen-Image-2512, FLUX 3 Image Klein, Krea 2, FLUX.1 schnell |
| filtering unknown | Juggernaut XL, Qwen-Image 2.1, LongCat-Image, LTX-Video |

Removed from the catalog in 0.5.2 (installed files stay): SD 3.5 Medium/Large, FLUX.1 dev,
Chroma v37 (use Chroma1-HD), HunyuanVideo 1.5 (license excludes the EU; use Wan 2.2).

## 3. Access from other projects

### Prerequisite

The NVAI-open server must be running. It listens on `http://127.0.0.1:8100`. With the Windows setup,
start it from the Start menu (**NVAI-open**); in a source checkout:

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
| `list_models(kind="image", detailed=True)` | models with `features` (section 8), pros and cons, license |
| `generate_image(...)` | generates images and blocks until done. Returns `files`, `asset_ids`, `seed`, and for FLUX 3 also `caption` |
| `list_assets(kind="image")` | latest images with asset ID and path |
| `copy_asset(asset_id, destination)` | copy an image into your own project |

After an NVAI-open update, a running session only sees the new tool descriptions after `/mcp` and
reconnecting.

### Via REST

| Method and path | Purpose |
|---|---|
| `GET /api/health` | status |
| `GET /api/version` | program, ComfyUI and contract version (`api`), supported extensions (`features`: `mask`, `references`, `upsampler` …). Check before first use |
| `GET /api/models?kind=image` | models with `features`, plus `recommended` and `gpu_note` for the detected card |
| `GET /api/models/search?q=…` | more models on Hugging Face (repos with checkpoint files) |
| `GET /api/models/inspect?repo=…&file=…` | checks a file before downloading: architecture from the safetensors header, size. SDXL and SD 1.5 checkpoints can be downloaded |
| `POST /api/generate/image` | create a job (JSON, fields as in section 7). Response: job with `id` |
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
- **The negative prompt works** (CFG 4). If it is left empty, NVAI-open inserts the one from Qwen's
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
  With 28 steps this took 82 s including a cold start. Since 0.5.6 **FLUX 3** fills too
  (`features.mask` = `"reference"`): NVAI-open cuts out the area with 35 % surroundings, greys it, lets
  FLUX 3 paint it from the prompt, measures the offset and puts back only the area, outside pixel for
  pixel. Measured on a fish market: crates removed with the cobblestones running on, a seagull added,
  about 60–70 s each. To rewrite something already there (lettering on a sign), edit with a reference
  image instead: filled grey, FLUX painted a new, frontal sign; as an edit it kept position and angle.
  Use the full model for new objects. In
  testing, Lightning mostly just continued the surroundings, which is enough for retouching
  something out.
- **Outpainting** (since 0.5.4, `image_asset_id` + `outpaint=[left, top, right, bottom]` in pixels):
  the image is extended beyond its edges; the size is image plus border. **Use FLUX 3:** it gets the
  image on a grey border as a reference and continues the scene, then NVAI-open puts the original back.
  FLUX 3 never returns the picture exactly in place (per axis 0.97–1.055 scale and up to 43 px offset,
  with a border on all sides it zoomed in by 25–42 %), so NVAI-open extends one axis at a time, measures
  the offset after each pass, moves the result back and only then puts the original in. Measured on a
  lion scene extended on all sides: two variants in 147 s, clean seams at full resolution. Qwen-Image-2512 extends via a mask, but in testing it painted the border
  as a separate scene with a hard edge (also with a 128/256 px transition and 50 steps).
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

### INT8 version for RTX 20/30/40 (`qwen-image-2512-int8`)

Only RTX 50 cards compute NVFP4 in hardware; an RTX 4060 needed 1095 s per image with it. For older
cards there is an INT8 version, quantized with Comfy-Org's own tool comfy-quants (int8 tensorwise
with ConvRot, the same layer selection as the official exports). It loads in stock ComfyUI without
a custom node and computes in hardware on every NVIDIA card from the RTX 20 series on. It is a
community upload (LAXMAYDAY, a byte-identical copy at wazimondo), 20.6 GB; text encoder and VAE are
shared with the NVFP4 versions.

Measured on an RTX 5060 Ti (16 GB), 1024 × 1024, 50 steps: 119 s per image, 132 s with loading
(NVFP4: 101 and 108 s). The test crate came out just as well as with NVFP4: lettering exact, rope
handles through drilled holes. With 16 GB or less, ComfyUI streams parts of the model from system
memory. On an RTX 4060 with 8 GB (on a riser, PCIe 3.0 x4): 653 s including loading, the NVFP4
version 1095 s; neither fits into 8 GB, but INT8 is computed in hardware. Lettering and rope handles
came out clean there too.

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
use the model without it. In NVAI-open it therefore runs automatically before every image:

1. From the request, the upsampler writes a description of 100 to 350 words. For non-square
   sizes it is told the aspect ratio and composes for it.
2. The image is generated from this description.
3. The description is returned as **`caption`**: directly in the return value via MCP, and in
   the asset's `meta.caption` via REST.

It decodes deterministically: the same prompt always yields the same description. NVAI-open caches
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

### Expand prompt: the upsampler for every model

The same upsampler also works for the other image models. In the web interface and in the
PhotoCraft add-on the **✨ Expand prompt** button writes the full description into the
prompt field; you read it, remove what is wrong, and generate with any model. Via MCP it is
`expand_prompt(prompt, width, height)`, via REST `POST /api/prompt/expand`. It needs a FLUX 3
model to be downloaded. Measured: 13–16 s, about 36 s right after a start.

NVAI-open for Mac (since 0.4) and the Mac PhotoCraft add-on have the same button and the same REST
route. There the Qwen3-4B text encoder of FLUX.2 Klein writes the description, with Black Forest
Labs' instructions for text-to-image prompts; no extra download. Measured on a Mac mini M1 with
8 GB: 22–25 s, 35 s the first time after starting the app.

With only "a medieval blacksmith", Qwen-Image-2512 painted a warrior portrait in leather armor;
with the expanded text it painted a working forge with hearth, anvil, tongs and sparks. The
upsampler fills every gap, though: it also gave the smith an iron helmet. Read the text first.

Since 0.5.3 the button is also on the **Video**, **Audio** and **3D** tabs (Windows). The same
upsampler then follows NVAI-open's own instructions (`target` in the API): for video it adds motion,
one camera move, setting and light; with LTX-2.5 also what can be heard; with a start image only
the motion. For Stable Audio it writes sound tags (source, material, room, microphone), for
Stable Audio 3 one sentence with genre, instruments, mood and BPM. On the 3D tab, "Object from text" first creates a
source image with the active image model: one closed object without floor or shadow. Measured
on the RTX 5060 Ti: 3–12 s per prompt. The model is trained on image descriptions; sound tags
sometimes still start with a full sentence.

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
natively up to 4K; the NVAI-open API allows up to 2048 × 2048. In measurements, 1440² brought more
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

NVAI-open detects the card (`compute_cap` via nvidia-smi) and marks suitable models in
`list_models` with `recommended`: on RTX 50 Qwen, FLUX 3 and LTX-2.5 in NVFP4, on older cards
Qwen-Image-2512, FLUX 3, Z-Image and LTX-2.5 in INT8. A format that the detected card does not compute in hardware gets a note in
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

## 6. Krea 2 Turbo (`krea2-turbo-nvfp4`)

### Key facts

- By Krea.ai, June 2026: a diffusion transformer with 12B parameters, released with open weights as
  Raw (for fine-tuning) and Turbo (distilled). NVAI-open uses Turbo with the values from ComfyUI's
  template `image_krea2_turbo_t2i.json`: 8 steps, CFG 1, sampler `euler`, scheduler `simple`.
- Text encoder Qwen3-VL-4B, byte for byte the file FLUX 3 uses; the VAE is Qwen-Image's, also
  identical (SHA-256 compared). With one of those models installed, only the 7.7 GB of Krea itself
  remain to download, otherwise 12.8 GB (plus 0.46 GB for the optional style LoRA). The files come from Comfy-Org/Krea-2, which unlike Krea's
  own repositories is not gated.
- Output from 1 to 2 MP according to Krea. The negative prompt has no effect (CFG 1).
- No mask, no second pass (`hires`). Since 0.5.10 one or two images as a style template (optional
  style LoRA, see below); for editing, FLUX 3 remains the choice.
- License: Krea 2 Community License, see below.

### Compared with Qwen and FLUX 3 (measured)

Same prompt and seed, RTX 5060 Ti, images checked at full resolution:

| Subject | Qwen-Image-2512 | FLUX 3 | Krea 2 Turbo |
|---|---|---|---|
| Old fisherman mending a net, 1024² (first image, with loading) | 160 s | 36 s | 41 s |
| Ammunition crate with lettering, 1024² | 109 s | 31 s | 21 s |
| Explorer in full body, 832 × 1216 | 113 s | 32 s | 20 s |

- **The most photographic of the three.** Hands and faces looked natural; skin, wool and leather
  have texture instead of the smooth AI look.
- **Text:** "MUNITION 7,92" came out letter-perfect, and the rope handles pass through drilled holes.
  The crate came without a lid, which the prompt did not mention: name what has to be there.
- **Full figure:** the standing explorer has both boots in the frame.
- **Name the framing.** The fisherman prompt stresses his weathered hands, and Krea cut his head off
  at the top in three of three images (two seeds, also at 1408 × 1408). With the sentence "Medium shot
  from the waist up, his whole head and face inside the frame with free space above his head." the
  head was in the frame in two of two. Without that sentence, FLUX 3 had the best composition.

### Run times (measured)

| Run | Time |
|---|---|
| 1024², 8 steps | 20–21 s |
| 1408 × 1408 (2 MP) | 37 s |
| first image after FLUX 3 (loading) | 41 s |

### Writing the prompt

As for Qwen: full English sentences, style and medium first, then the subject with material, color
and construction, then light and background; text verbatim in quotation marks. State the framing
("medium shot from the waist up", "full body, both boots inside the frame"). Krea 2 is trained on
detailed descriptions; expand a few words with **✨ Expand prompt** first (Krea's own template does
the same).

### Style template (since 0.5.10)

With ostris' style LoRA (`ostris/krea2_turbo_style_reference`, 0.46 GB, Krea 2 Community License, not
gated) Krea 2 takes one or two images as a style template. The way of painting, the colors and the light
come from the image, the content from the prompt. The LoRA is optional: a new download of Krea 2 includes
it, for an installed Krea 2 "Download extras" under "Models" fetches it. Until then `features.references`
is 0 and `features.missing.style_reference` names the Hugging Face page. The images go into
`reference_asset_ids` as with FLUX 3; the web interface labels them as style templates.

Measured at 1024², prompt "A lighthouse on a rocky cliff above a stormy sea, waves crashing against the
rocks below.", templates made with FLUX 3 (picture in section 2):

| Run | Time | Result |
|---|---|---|
| without a template | 24 s | photographic, dark storm clouds |
| watercolor template | 48 s | watercolor; the stormy sky took the pastel evening light of the template |
| woodcut template | 41 s | woodcut in black, red and cream like the template |
| both templates | 71 s | almost completely the first template |

Describe only the content in the prompt. Light and colors come from the template even where the prompt
says otherwise (the storm became pastel); with two templates the first one wins, so one is enough. Krea
takes the style of the template, not its content: to change an image, FLUX 3 remains the choice.

The graph follows ComfyUI's template `image_krea2_turbo_int8_image_style_reference.json`: the LoRA at
strength 1.0, `ModelSamplingFlux` (1.15 / 0.5), the images through `TextEncodeQwenImageEditPlus` (the
Qwen3-VL encoder has the vision part) and `FluxKontextMultiReferenceLatentMethod`, 8 steps, CFG 1.

### License: Krea 2 Community License

- Commercial use only below US$1 million annual revenue, including affiliated companies.
- A content filter or a review of every image by hand is required.
- Label images as AI-generated where the law requires it.
- Krea can terminate the license with 30 days' notice.
- Without these conditions: Qwen-Image-2512 (Apache-2.0).

### INT8 version for RTX 20/30/40 (`krea2-turbo-int8`)

Comfy-Org's INT8 version (ConvRot), computed in hardware on every NVIDIA card from the RTX 20 series
on. The model file is 13.5 GB (18.6 GB with text encoder and VAE); on cards with less memory ComfyUI
streams parts from system memory.

Measured on an RTX 4060 with 8 GB (on a riser, PCIe 3.0 x4), 1024 × 1024, the crate from above: 193 s for
the first image, then 82 s, lettering exact as with NVFP4. The NVFP4 version took 46 s on the same card
including loading, although the 4060 has no FP4 units: at 7.7 GB it fits into the graphics memory, the
INT8 version at 13.5 GB does not and is streamed over the slow riser (3.9 GB/s) at every step. On a
normal connection it is the other way round: the RTX 5060 Ti without its FP4 units (PCIe 4.0 x8)
took 13.0 instead of 25.1 s with INT8 at 8 GB and 12.2 instead of 25.0 s at 16 GB. **On RTX 20/30/40,
use the INT8 version, NVFP4 only on a slow connection (up to 4 GB/s)**; this is what NVAI-open
recommends (section 2, New in 0.5.10).

## 7. `generate_image` parameters

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
| `mask_asset_id` | ✓ inpainting (with `image_asset_id`, `denoise=1.0`) | ✓ since 0.5.6 via a reference: area greyed, put back aligned | white = new, black = keep; upload the mask via `POST /api/upload` |
| `outpaint` | ✓ via mask, often a hard edge | ✓ seamless, original pixel for pixel | `[left, top, right, bottom]`, the size follows |
| `reference_asset_ids` | — | up to 10 | error message with other models |
| `upsample_prompt` | — | on by default | |
| `slg`, `controlnet_*` | — | — | only for SD 3.5 models (no longer in the catalog) |

Size by silhouette: standing figure 832 × 1216 (Qwen native 1056 × 1584), vehicle in landscape
1216 × 832 (1584 × 1056), object and icon 1024 × 1024 (1328 × 1328).

## 8. The `features` field

`GET /api/models` and `list_models(detailed=True)` return a `features` field for each image
model. Other programs can adapt their controls to it, as the NVAI-open web UI does.

| Key | Meaning | Qwen-50 | FLUX 3 |
|---|---|---|---|
| `steps`, `cfg` | defaults | 50, 4.0 | 16, 1.0 |
| `negative_prompt` | does the negative prompt work? | true | false |
| `default_negative` | applies when none is given | Qwen's default | empty |
| `upsampler` | prompt upsampler available | false | true |
| `references` | maximum number of reference images | 0 | 10 |
| `bbox` | placement by box | false | true |
| `img2img` | start image with `denoise` | true | false |
| `mask` | inpainting with `mask_asset_id` (true = mask, `"reference"` = through a greyed reference image) | true | "reference" |
| `outpaint` | how extending works (`"mask"`, `"reference"`, null) | "mask" | "reference" |
| `hires` | second pass useful | true | false |
| `text_rendering` | text in the image | true | true |
| `sizes` | additional recommended sizes `{label, w, h}` | 7 native | 4, up to 2048² |
| `prompt_hint` | short prompt guide, in the request language (English by default) | ✓ | ✓ |
| `placeholder` | example prompt | ✓ | ✓ |

## 9. Known pitfalls

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
- **ComfyUI 0.41 or newer** for FLUX 3. `install.ps1` pins v0.42.1.
- **Check results at full resolution:** downscaled previews hide exactly the errors that matter,
  such as a rope handle without a hole.

## 10. For maintainers

| What | Where |
|---|---|
| Catalog entries, `features`, texts | `server/nvai/catalog.py` |
| ComfyUI graphs (`build_qwen_image`, `build_flux3`, `build_krea2`) | `server/nvai/workflows.py` |
| Upsampler, box logic, cache | `server/nvai/flux3_prompt.py` (based on BFL's reference code, Apache-2.0) |
| BFL's upsampler system prompts | `server/nvai/flux3_pup_prompts.json` |
| Flow (upsampler, then image; providing references) | `server/nvai/jobs.py`, `_txt2img` |
| MCP instructions and tool texts | `server/nvai/mcp_server.py` |
| Model files | `external/comfyui/models/{diffusion_models,text_encoders,vae,loras}` (the Windows setup uses the model folder chosen during installation) |

The graphs are modeled on the templates that ship with ComfyUI: `image_qwen_Image_2512.json`,
`image_flux3_klein_*`, `image_krea2_turbo_t2i.json` and, for the style template,
`image_krea2_turbo_int8_image_style_reference.json`. The CLIPLoader types are `qwen_image`,
`flux3` and `krea2`, the empty latent is `EmptySD3LatentImage`, `EmptyFlux2LatentImage` or
`EmptyLatentImage` respectively, references go through
`ReferenceMultiLatent`, the upsampler through `TextGenerate`.
