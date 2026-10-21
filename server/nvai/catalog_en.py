"""English texts for the model catalog (catalog.py stays the German source).
registry.to_info overlays these when the request language is English."""
from __future__ import annotations

from typing import Any

# Shared texts, English counterparts of the constants of the same name in catalog.py.
QWEN_PROMPT_HINT = (
    "Full sentences instead of keywords: first medium and style, then the subject with "
    "material, color and condition, then lighting and background. Qwen renders text in "
    "quotation marks letter for letter. State the construction explicitly (\"rope handles "
    "pass through drilled holes\"), otherwise it gets invented."
)
FLUX3_PROMPT_HINT = (
    "Describe briefly and completely: style, subject, count, arrangement, construction. The "
    "upsampler turns this into the long image description FLUX 3 is trained on — without a "
    "style it plans a photo, and whatever is left open it invents (in testing, a coat as a "
    "cape). Text in quotation marks stays verbatim. In the prompt, reference images are "
    "called \"the first image\", \"the second image\", etc."
)
FLUX3_LICENSE_WARNING = (
    "FLUX Kommunity License: commercial use of images only below US$5 million in annual "
    "revenue (including affiliated companies), review every image before publication, label "
    "as AI-generated where required by law. BFL can terminate the license at any time."
)
QWEN21_LICENSE_WARNING = (
    "Qwen Research License: research and evaluation only, no commercial use — including no "
    "images for a game you sell. For final assets use Qwen-Image-2512 (Apache-2.0)."
)
_LICENSE_CON_FLUX3 = (
    "Kommunity license instead of Apache: revenue cap, review obligation, can be "
    "terminated at any time"
)
_GATED_CON_FLUX3 = "Repo is gated: accept the license on Hugging Face and store a token"

# Per model id: only fields that contain German text. Allowed keys:
# name, best_for, description, pros, cons, warning, license (only if German words),
# features (dict with prompt_hint and/or placeholder only).
EN: dict[str, dict[str, Any]] = {
    # ------------------------------------------------------------ IMAGE
    "sdxl-base": {
        "best_for": "All-rounder and starting point for your own styles",
        "description": (
            "The base model around which the scene's largest ecosystem has grown. "
            "Unspectacular on its own, but every LoRA, every ControlNet and every "
            "fine-tune for game art builds on it. If you need a consistent look across "
            "hundreds of assets, you will end up training a LoRA — and it will be "
            "SDXL-based."
        ),
        "pros": [
            "Huge selection of LoRAs, ControlNets and fine-tunes",
            "Very frugal: ~8 GB VRAM, plenty of headroom for parallel work",
            "Fast (~12 s for 1024², 28 steps on the 5060 Ti)",
            "License unproblematic for commercial games",
        ],
        "cons": [
            "Prompt adherence well below FLUX/SD3.5 — long prompts are ignored",
            "Text in images is practically unusable",
            "Often dull out of the box; needs good prompts or a fine-tune",
        ],
    },
    "juggernaut-xl-v9": {
        "best_for": "Realistic textures, materials, environment references",
        "description": (
            "SDXL fine-tune focused on photorealism. For game dev it is strongest when "
            "you need material and texture references: stone, metal, fabric, rust, "
            "wood. Also for concept art of environments that should look realistic."
        ),
        "pros": [
            "Much better out-of-the-box results than SDXL Base",
            "Very good at materials and surfaces",
            "Fully LoRA-compatible with SDXL",
        ],
        "cons": [
            "Pulls everything toward photorealism — unsuitable for stylized work",
            "Inherits SDXL's weaknesses in prompt adherence and text",
        ],
    },
    "illustrious-xl": {
        "best_for": "Stylized 2D assets, characters, anime/cartoon look",
        "description": (
            "The standard for stylized 2D art. Understands tag-based prompts (Danbooru "
            "style) very precisely, which helps enormously with character assets: pose, "
            "clothing, expression and perspective can be controlled deliberately. For 2D "
            "games or stylized UI assets usually the better choice than SDXL Base."
        ),
        "pros": [
            "Excellent control over character features via tags",
            "Consistent style across many generations",
            "Very active LoRA scene",
        ],
        "cons": [
            "Tag syntax takes learning — natural language works worse",
            "Unsuitable for photorealism or environments",
            "License requires derived models to remain open",
        ],
    },
    "flux1-schnell-fp8": {
        "best_for": "Complex prompts, fast iteration, commercial use",
        "description": (
            "The best compromise between quality, speed and license. Understands long, "
            "nested prompts that SDXL ignores completely, and needs only 4 steps to do "
            "so. Apache-2.0 means: commercially usable without restriction — unlike "
            "FLUX.1 dev. For game assets meant for a game that will be sold, this is my "
            "default recommendation."
        ),
        "pros": [
            "Excellent prompt adherence, understands relationships between objects",
            "Only 4 steps needed — fast despite its size",
            "Apache-2.0: no license worries",
            "Usable text in images",
        ],
        "cons": [
            "16 GB download; ComfyUI offloads the text encoder to the CPU",
            "First run after loading takes noticeably longer",
            "Negative prompts have no effect (CFG 1.0)",
            "Fewer LoRAs than for SDXL",
        ],
    },
    "z-image": {
        "best_for": "Prompt adherence on mid-range cards — 6 B parameters with a strong encoder",
        "description": (
            "Much smaller than Chroma (6 instead of 8.9 billion parameters), yet follows "
            "long descriptions very closely. The text encoder is Qwen3-4B, a real "
            "language model instead of CLIP — so multi-part scenes are rendered more "
            "reliably. Not CFG-distilled, so the negative prompt works (cfg 4.0); the "
            "Turbo variant cannot do that. The VAE is the same Flux VAE as in Chroma and "
            "LongCat — if one of them is installed, 0.3 GB of the download is skipped."
        ),
        "pros": [
            "Very good prompt adherence with a third of the parameters of larger models",
            "Negative prompt works (cfg 4.0)",
            "Apache-2.0",
            "Runs on 12 GB cards with headroom",
        ],
        "cons": [
            "Newer and less proven than Chroma",
            "Hardly any LoRAs available",
            "Encoder and model do not fit on 8 GB — use the int8 version there",
        ],
    },
    "z-image-int8": {
        "name": "Z-Image (int8, for small cards)",
        "best_for": "The choice for 8 GB cards — the same model, heavily quantized",
        "description": (
            "The same model as `z-image`, but in int8 instead of bf16 and with a text "
            "encoder quantized to fp4: 9.3 GB download instead of 17, and the memory "
            "requirement drops to about 7 GB. That lets it run on an 8 GB card. "
            "Quantization costs some detail fidelity — on a card that cannot hold the "
            "large version, it is still the better trade: a model held in memory is many "
            "times faster than one that is reloaded at every step."
        ),
        "pros": [
            "Runs on 8 GB VRAM",
            "Only 9.3 GB download",
            "Negative prompt works",
            "Apache-2.0",
        ],
        "cons": [
            "Slight quality loss compared with the bf16 version",
            "int8/fp4 requires a sufficiently recent card (RTX 40 or newer)",
        ],
    },
    "qwen-image-2512-lightning": {
        "name": "Qwen-Image-2512 (NVFP4, Lightning 8 steps)",
        "best_for": "Quick drafts with the strongest Apache model — final assets with 50 steps",
        "features": {
            "prompt_hint": QWEN_PROMPT_HINT + " The negative prompt has no effect here "
                           "(cfg 1) — phrase exclusions positively.",
        },
        "description": (
            "Qwen-Image-2512 has 20 billion parameters and is the top-ranked open image "
            "model with an Apache license (Arena Elo 999, as of October 2026). In bf16 "
            "that would be 41 GB — here in NVFP4 it is 14.9 GB, and RTX 50 cards "
            "compute this format in hardware.\n\n"
            "The Lightning LoRA shortens sampling from 50 to 8 steps at cfg 1. As a "
            "result the negative prompt no longer works; phrase exclusions positively or "
            "use the full version `qwen-image-2512-nvfp4`. Both share the same files.\n\n"
            "The text encoder is Qwen2.5-VL-7B, a real language model: long, multi-part "
            "descriptions and text in images succeed much more reliably than with CLIP. "
            "Native resolution is 1328 × 1328; the ~1 MP sizes from the size table work "
            "as well.\n\n"
            "Measured on an RTX 5060 Ti with PyTorch cu130: about 17 s per image at "
            "1024 × 1024, 28 s on the first run after startup. `batch_size=4` pays off: "
            "40 s for four images."
        ),
        "pros": [
            "Apache-2.0, top-ranked open model with a commercial license",
            "8 steps instead of 50",
            "NVFP4: 20 billion parameters in 14.9 GB instead of 41 GB",
            "Qwen2.5-VL as encoder: long prompts, text in images",
        ],
        "cons": [
            "Loses construction details: with the same seed, a crate's rope handles lay "
            "loose on the wood without drilled holes, while the 50-step version passed them "
            "through holes",
            "Negative prompt has no effect (cfg 1.0)",
            "Community quantization, not an official release — slight quality loss "
            "compared with bf16",
            "Encoder (9.4 GB) and model (14.9 GB) do not fit into 16 GB at the same time — "
            "every new prompt pays for a reload cycle",
            "Needs PyTorch cu130 in the ComfyUI venv — with cu128 every image takes three "
            "times as long (measured 50 instead of 17 s)",
        ],
    },
    "qwen-image-2.1-int8": {
        "name": "Qwen-Image 2.1 (INT8, 25 steps) — non-commercial",
        "warning": QWEN21_LICENSE_WARNING,
        "best_for": "Trying out: editing with up to ten reference images, text — "
                    "non-commercial only",
        "description": (
            "Qwen (Alibaba), September 2026. Successor of Qwen-Image-2512 with 7 billion "
            "parameters in the image part and Qwen3-VL-8B as text encoder. One model for "
            "text-to-image and editing: up to ten reference images, according to Qwen also "
            "transparent images (RGBA) and better text. This version is ComfyUI's INT8 "
            "package, settings as in ComfyUI's template: 25 steps, cfg 1 — so the negative "
            "prompt has no effect.\n\n"
            "Measured on the RTX 5060 Ti: 1024² in 26 s, 1344 × 1792 in 64 s, first run "
            "with loading 109 s; editing with one reference image 34–38 s. Text-to-image "
            "was very clean in the test, text letter-perfect. When editing, shape and text "
            "were kept, but the result looked overprocessed (harsh contrast, grainy "
            "background) — also with 50 steps and exactly ComfyUI's template graph.\n\n"
            "**Non-commercial use only.** The Qwen Research License allows research and "
            "evaluation; any commercial use, including images for a game you sell, needs a "
            "separate license from Alibaba. For final assets use Qwen-Image-2512 "
            "(Apache-2.0) or FLUX 3."
        ),
        "pros": [
            "Editing with up to ten reference images",
            "Text in the image",
            "Smaller than Qwen-Image-2512: 7 instead of 20 billion parameters in the image part",
        ],
        "cons": [
            "Qwen Research License: non-commercial only — not for assets in a game you sell",
            "cfg 1: the negative prompt has no effect",
            "Editing looked overprocessed in the test: harsh contrast, grainy background",
        ],
        "features": {"prompt_hint": QWEN_PROMPT_HINT + " In the prompt, reference images are "
                                    "called <image1>, <image2>, etc.; the first one is the image being edited."},
    },
    "qwen-image-2512-nvfp4": {
        "name": "Qwen-Image-2512 (NVFP4, full 50 steps)",
        "best_for": "Final assets — construction details are much more accurate than with Lightning",
        "features": {
            "prompt_hint": QWEN_PROMPT_HINT + " Without a negative prompt of your own, the "
                           "one from Qwen's model card applies.",
        },
        "description": (
            "The same model as `qwen-image-2512-lightning`, but without distillation: "
            "50 steps at cfg 4.0. That takes many times as long, but the negative prompt "
            "works and textures stay closer to the unquantized original. Measured on an "
            "RTX 5060 Ti with PyTorch cu130: about 93 s per image at 1024 × 1024. Under "
            "cu128 it was 500 s.\n\n"
            "With the same seed much better than Lightning: the test crate's rope handles "
            "ran through drilled holes and under the battens instead of lying on the wood "
            "without support. Use this version for final assets, Lightning only for "
            "drafts.\n\n"
            "Qwen's model card recommends as negative prompt: `低分辨率，低画质，肢体畸形，"
            "手指畸形，画面过饱和，蜡像感，人脸无细节，过度光滑，画面具有AI感。构图混乱。"
            "文字模糊，扭曲` (low resolution, deformed limbs and fingers, oversaturated, "
            "waxy, too smooth, AI look, chaotic composition, distorted text)."
        ),
        "pros": [
            "Structurally more coherent than Lightning: rope handles through drilled holes "
            "instead of laid on loosely",
            "Negative prompt works (cfg 4.0)",
            "No distillation — closer to the original",
            "Apache-2.0",
            "Shares all files with the Lightning version",
        ],
        "cons": [
            "50 steps with two passes each — many times the Lightning time",
            "Encoder and model do not fit into 16 GB at the same time",
        ],
    },
    "flux3-klein-nvfp4": {
        "name": "FLUX 3 Image Klein (NVFP4, 16 steps)",
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "Editing with reference images, consistent characters, placement by box — fast",
        "description": (
            "Black Forest Labs, October 2026. 5.6 billion parameters, text encoder "
            "Qwen3-VL-4B. One model for text-to-image and editing: up to ten reference "
            "images, referred to in the prompt as \"the first image\", \"the second "
            "image\". This lets you keep characters consistent across several images, "
            "replace parts or combine subjects — none of the other models here can do "
            "that.\n\n"
            "The distilled version is BFL's production model (the same one behind their "
            "API): 16 steps without guidance, so the negative prompt has no effect.\n\n"
            "Before each image, a bundled upsampler (Qwen3.5-9B) expands the prompt into a "
            "full image description — according to BFL, the model is trained on exactly "
            "that, and short prompts would otherwise give generic images. The expanded "
            "description is stored in the asset under \"caption\". NV-AI takes repeated "
            "prompts from the cache.\n\n"
            "Elements can be placed with a bounding-box table at the end of the prompt "
            "([top, left, bottom, right] on a 0–1000 grid). The boxes steer position and "
            "size, but are not a hard mask.\n\n"
            "Measured on an RTX 5060 Ti (NVFP4, cu130, ComfyUI 0.41.3) at 1024 × 1024: "
            "new prompt about 30 s (upsampler 8–15 s, image 12 s), same prompt with a new "
            "seed 13–16 s, four images 37 s, 1440 × 1440 in 26 s, editing with one "
            "reference image 45 s.\n\n"
            "In testing: text error-free three times out of three (\"MUNITION 7,92\"), "
            "five out of five soldiers complete with feet, three crates exactly at the box "
            "positions, and when editing, the source image stayed unchanged except for the "
            "handles. Weaknesses: without a style the upsampler plans a photo, and whatever "
            "the prompt leaves open it invents — it hung a coat over the soldiers' backs "
            "like a cape, and rope handles hung loosely over the front instead of forming "
            "a loop. Specify explicitly what matters and check the `caption`. "
            "Qwen-Image-2512 with 50 steps handles construction more reliably.\n\n"
            "License: FLUX Kommunity License — see warning."
        ),
        "features": {
            "prompt_hint": FLUX3_PROMPT_HINT + " The negative prompt has no effect here (cfg 1).",
        },
        "pros": [
            "Editing with a reference image: in testing the source image stayed unchanged "
            "except for the modified handles",
            "Up to 10 reference images: keep characters consistent, combine subjects",
            "Box placement hit all three positions in testing",
            "Fast: 13–16 s per image for a known prompt, about 30 s for a new one",
            "Text error-free three times out of three in testing",
            "Official NVFP4 version from BFL, computed in hardware on RTX 50",
        ],
        "cons": [
            _LICENSE_CON_FLUX3,
            "Upsampler invents whatever is left open (coat as a cape, loosely hanging "
            "ropes) — specify what matters explicitly",
            "Rope handles three times without a sensible attachment in testing — Qwen 50 "
            "does construction better",
            "Photorealistic without a style specification",
            "Negative prompt has no effect (distilled, cfg 1)",
            _GATED_CON_FLUX3,
        ],
    },
    "flux3-klein-int8": {
        "name": "FLUX 3 Image Klein (INT8, for RTX 20/30/40)",
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "FLUX 3 on cards without FP4 (RTX 20/30/40) with 8 GB of video memory or more",
        "description": (
            "The same model as FLUX 3 Image Klein (NVFP4), but in BFL's INT8 version. "
            "INT8 is computed in hardware on every NVIDIA card from RTX 20 onward; NVFP4 "
            "only on RTX 50 — on older cards it is unpacked layer by layer and is much "
            "slower.\n\n"
            "As in BFL's own INT8 template, with the smaller upsampler (w4a8, 6.7 instead "
            "of 9.8 GB). According to BFL this version runs on 8 GB cards such as the "
            "RTX 3070, and on an RTX 4070 in under 9 s per image (16 steps, 1 megapixel). "
            "Not yet measured by us.\n\n"
            "Everything else — reference images, box placement, upsampler, prompt rules — "
            "as with the NVFP4 version.\n\n"
            "License: FLUX Kommunity License — see warning."
        ),
        "features": {
            "prompt_hint": FLUX3_PROMPT_HINT + " The negative prompt has no effect here (cfg 1).",
        },
        "pros": [
            "Runs in hardware on RTX 20/30/40, according to BFL with as little as 8 GB of "
            "video memory",
            "Reference images, box placement and upsampler like the NVFP4 version",
            "Upsampler 3 GB smaller (w4a8), as in BFL's INT8 template",
        ],
        "cons": [
            _LICENSE_CON_FLUX3,
            "On RTX 50 the NVFP4 version is the faster choice",
            "Not yet measured by us — timings and quality are BFL's figures",
            _GATED_CON_FLUX3,
        ],
    },
    "flux3-klein-base-nvfp4": {
        "name": "FLUX 3 Image Klein Base (NVFP4, 50 steps)",
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "FLUX 3 with an effective negative prompt — undistilled, 50 steps",
        "description": (
            "The same model as `flux3-klein-nvfp4`, but undistilled: 50 steps at CFG 3.5, "
            "two passes per step. BFL offers this version mainly for fine-tuning and LoRA "
            "training; in exchange, the negative prompt works here.\n\n"
            "Shares text encoder, upsampler and VAE with the distilled version — only "
            "5.3 GB more to download.\n\n"
            "Measured: 53 s at 1024 × 1024 (1.09 steps per second with CFG). In testing no "
            "recognizable advantage over the distilled version — with the same description "
            "the rope handles hung just as loosely."
        ),
        "features": {
            "prompt_hint": FLUX3_PROMPT_HINT + " The negative prompt works (cfg 3.5).",
        },
        "pros": [
            "Negative prompt works (CFG 3.5)",
            "Undistilled — a basis for your own LoRAs",
            "Shares all additional files with the distilled version",
        ],
        "cons": [
            _LICENSE_CON_FLUX3,
            "53 instead of 13 s per image — no visible gain in testing",
            "BFL names the distilled version as its production model",
        ],
    },
    "longcat-image": {
        "best_for": "Scenes with several objects and an action",
        "description": (
            "Flux architecture with Qwen2.5-VL as text encoder — the same language model "
            "that HunyuanVideo 1.5 uses. As a result it understands long, multi-part "
            "descriptions much better than a CLIP-based model, which splits the prompt "
            "into 77-token blocks.\n\n"
            "Not CFG-distilled: the negative prompt really works (cfg 4.0), unlike with "
            "FLUX schnell.\n\n"
            "Of the 21.4 GB, only **11.7 GiB are actually new** — text encoder and VAE are "
            "already on disk from HunyuanVideo and Chroma and are reused."
        ),
        "pros": [
            "Only ~11.7 GiB of actual download — encoder and VAE are already there",
            "Qwen2.5-VL understands long scene descriptions without 77-token blocks",
            "Negative prompt works (cfg 4.0)",
            "Apache-2.0",
        ],
        "cons": [
            "Encoder (9.4 GB) and model (12.5 GB) do not fit into 16 GB at the same time — "
            "every run pays for a reload cycle",
            "New and little tested; hardly any LoRAs or ControlNets available",
            "Only text-to-image in NV-AI; the edit variant is not integrated",
        ],
    },
    "chroma1-hd-fp8": {
        "name": "Chroma1-HD (fp8, fits in memory)",
        "best_for": "First choice for scene images — follows long prompts best",
        "description": (
            "The same Chroma1-HD, but in mixed fp8 instead of bf16: 8.6 instead of "
            "16.6 GB. That is the decisive difference on a 16 GB card — the bf16 file "
            "physically does not fit and has to be reloaded over PCIe at every sampling "
            "step, which stretches an image from about 30 to 110 seconds.\n\n"
            "Unchanged in substance: developed further from FLUX.1 schnell, Apache-2.0, "
            "no content filter, and with a working negative prompt (unlike FLUX schnell, "
            "which is CFG-distilled). Exactly the file that ComfyUI's own Chroma template "
            "loads.\n\n"
            "For narrative scenes with several objects and an action, it was the most "
            "accurate of the models available here in a direct comparison."
        ),
        "pros": [
            "Fits completely in memory — about three times faster than the bf16 version",
            "Negative prompt really works (cfg 4.0), unlike with FLUX schnell",
            "Best prompt adherence for long scene descriptions in the test comparison",
            "Apache-2.0, no content filters",
        ],
        "cons": [
            "fp8 instead of bf16 — minimal quality loss compared with the large file",
            "Needs more steps than FLUX schnell",
            "Community project without a support guarantee",
        ],
    },
    "chroma1-hd": {
        "name": "Chroma1-HD (bf16 — too large for 16 GB)",
        "warning": "At 16.6 GB it does not fit on the card — use the fp8 version",
        "best_for": "Only sensible with more than 16 GB VRAM — otherwise use the fp8 version",
        "description": (
            "The full bf16 version. Identical in substance to `chroma1-hd-fp8`, but the "
            "file alone weighs 16.6 GB and therefore does not fit on a 16 GB card. ComfyUI "
            "then reloads it piece by piece over PCIe at every sampling step — measured at "
            "about 110 seconds per image instead of about 30.\n\n"
            "Only keep it if a larger card is involved. Otherwise `chroma1-hd-fp8` is the "
            "better choice in every respect: same model, 8 GB less, three times the speed."
        ),
        "pros": [
            "Full bf16 precision without quantization loss",
            "Apache-2.0, no content filters",
        ],
        "cons": [
            "16.6 GB model file — does not fit into 16 GB VRAM",
            "Constant reloading over PCIe: about three times slower than fp8",
            "21.7 GB download for a result the fp8 version delivers faster",
        ],
    },
    "pony-v6-xl": {
        "best_for": "Characters and creatures, unfiltered, huge LoRA ecosystem",
        "description": (
            "Despite the name, a broadly usable SDXL fine-tune and one of the most widely "
            "used bases in the scene — a large share of all character LoRAs builds on it. "
            "Unfiltered and very controllable via quality tags (score_9, score_8_up …), "
            "which you do have to know. Strong for stylized characters, creatures and "
            "monsters."
        ),
        "pros": [
            "CDLA-Permissive-2.0 — one of the most permissive licenses there is",
            "No content filters",
            "Enormous LoRA ecosystem for characters",
            "Only 6.5 GB and ~8 GB VRAM",
        ],
        "cons": [
            "Its own prompt syntax with score tags — without them results are poor",
            "Largely ignores natural language",
            "Unsuitable for realistic environments",
        ],
    },
    "noobai-xl-v1.1": {
        "best_for": "Stylized 2D assets without filters, broader knowledge than Illustrious",
        "description": (
            "Built on Illustrious and trained considerably further. Knows more "
            "characters, styles and concepts than the original and filters nothing. If "
            "Illustrious suits a subject but shies away from the content, this is the "
            "direct replacement."
        ),
        "pros": [
            "Unfiltered, while offering very good tag control",
            "Greater concept knowledge than Illustrious v0.1",
            "SDXL-compatible: LoRAs and ControlNets work",
        ],
        "cons": [
            "Tag syntax required (Danbooru style)",
            "Fair AI license requires derived models to remain open",
            "Not for photorealism",
        ],
    },
    "sdxl-vae-fp16": {
        "best_for": "Accessory: fixes artifacts in SDXL fine-tunes",
        "description": (
            "Not a standalone model but a replacement VAE. Helps when SDXL fine-tunes "
            "produce black areas or color casts."
        ),
        "pros": ["Tiny", "Fixes known fp16 artifacts"],
        "cons": ["Useless on its own — only in combination with an SDXL checkpoint"],
    },
    # ------------------------------------------------------------ AUDIO
    "stable-audio-open-1.0": {
        "best_for": "Sound effects and ambient loops — the game dev use case",
        "description": (
            "Trained on sound effects and soundscapes, not on songs. Exactly what you "
            "constantly need when building games: footsteps on gravel, sword strike, "
            "creaking door, rain, campfire, crowd. Generates up to 47 seconds at 44.1 kHz "
            "stereo. Describe the sound, not the music."
        ),
        "pros": [
            "Clearly the best candidate for SFX and ambience",
            "Only ~6 GB VRAM, runs alongside other work",
            "47 s in one go is enough for loops",
            "One file, no additional encoders",
        ],
        "cons": [
            "Cannot do structured music or vocals",
            "Community License with a USD 1 million revenue cap",
            "Results often need post-processing (cutting, loop points)",
        ],
    },
    "ace-step-v1-3.5b": {
        "best_for": "Complete pieces of music including vocals",
        "description": (
            "Generates complete songs from genre tags and optional lyrics — with sung "
            "vocals. For title music, battle themes or a tavern with a bard's song. "
            "Control works via tags (\"epic orchestral, choir, drums\") plus a lyrics "
            "field. Apache-2.0 makes it commercially safe."
        ),
        "pros": [
            "Generates structured music with vocals — unique in this selection",
            "Apache-2.0: no revenue cap, no license worries",
            "Pieces several minutes long are possible",
            "Tag control is very handy for game moods",
        ],
        "cons": [
            "Vocals often sound artificial, pronunciation is shaky",
            "~9 GB VRAM and much slower than Stable Audio",
            "Overkill for short SFX",
        ],
    },
    "ace-step-1.5-turbo": {
        "best_for": "Better music quality than v1, with more control",
        "description": (
            "Successor to ACE-Step v1 with cleaner musicality and many more controls: "
            "BPM, key, time signature and language are direct parameters instead of hints "
            "in the prompt. The Turbo variant needs fewer steps than the base model."
        ),
        "pros": [
            "Audibly better than v1 in instrumentation and structure",
            "BPM/key/time signature directly controllable — important for adaptive game music",
            "Apache-2.0",
        ],
        "cons": [
            "11 GB VRAM: tight alongside an image model",
            "9.3 GB download",
            "Newer and less proven than v1",
        ],
    },
    # ------------------------------------------------------------ VIDEO
    "wan21-t2v-1.3b": {
        "best_for": "The entry point to video — runs comfortably on 16 GB",
        "description": (
            "The small Wan model is the most sensible starting point for your card: only "
            "1.3B parameters, ~8 GB VRAM, and still temporally stable clips. Typical is "
            "480p and 3–5 seconds at 16 fps. Useful for games for animated textures, "
            "effect loops, background videos or trailer snippets."
        ),
        "pros": [
            "Runs with headroom on 16 GB — no offload needed",
            "Apache-2.0, commercially unrestricted",
            "Good temporal consistency for its size",
            "Fastest way to a first video",
        ],
        "cons": [
            "480p and a few seconds — not finished trailer material",
            "Details flicker, text in the image falls apart",
            "Three-part download (model + encoder + VAE)",
        ],
    },
    "wan22-ti2v-5b": {
        "best_for": "Best video quality that actually fits on 16 GB",
        "description": (
            "Wan 2.2 in the 5B variant was built specifically for consumer cards and "
            "handles text-to-video and image-to-video in the same model. 720p becomes "
            "achievable. If you want to see a generated concept image in motion, this is "
            "the right pick."
        ),
        "pros": [
            "Text-to-video and image-to-video in one model",
            "Much better motion and detail fidelity than 1.3B",
            "720p realistically achievable",
            "Apache-2.0",
        ],
        "cons": [
            "~13 GB VRAM: nothing else runs in parallel",
            "16.9 GB download",
            "Noticeably slower — several minutes per clip",
        ],
    },
    "wan22-i2v-a14b": {
        "best_for": "Best image-to-video that runs on 16 GB — brings a still image to life convincingly",
        "description": (
            "Two experts of 14B each share the run: the high-noise expert lays out motion "
            "and composition, the low-noise expert draws in the details. ComfyUI loads them "
            "one after the other, so the model fits on your card despite 2×13.3 GB — it "
            "only costs a model switch in the middle of the run.\n\n"
            "Human motion, fabric, water and camera moves are much more convincing here "
            "than with anything else in the catalog. Unlike Wan 2.1 I2V, this model needs "
            "no CLIP Vision: the start image goes directly into the conditioning."
        ),
        "pros": [
            "By far the best image-to-video quality here",
            "Motion and anatomy stay consistent throughout the clip",
            "Apache-2.0 — commercially usable without restriction",
            "720p possible, 480p very solid",
        ],
        "cons": [
            "33 GB download — the largest item in the catalog",
            "Model switch in the middle of the run: expect many minutes per clip",
            "~14 GB VRAM per expert: free VRAM beforehand",
            "Requires a start image",
        ],
    },
    "ltxv-2b-095": {
        "best_for": "Fast iteration — video preview in seconds instead of minutes",
        "description": (
            "Optimized for speed and often generates clips faster than their playback "
            "length. Just right for trying out twenty variants of an idea before you put "
            "the good model on it. Lower quality than Wan 2.2, but orders of magnitude "
            "faster."
        ),
        "pros": [
            "By far the fastest video model here",
            "Only 5.9 GB download, one file",
            "Ideal for trying out motion ideas",
        ],
        "cons": [
            "Visibly weaker than Wan in detail and consistency",
            "Needs very detailed prompts, otherwise little happens",
            "Its own license — read it before commercial use",
        ],
    },
    "wan21-i2v-480p-14b": {
        "best_for": "Previous-generation image-to-video — only if Wan 2.2 does not fit",
        "description": (
            "The large 14B model from the Wan 2.1 series in fp8. Brings a still image to "
            "life decently, but has since been overtaken by Wan 2.2 I2V A14B — there the "
            "motion is cleaner and the anatomy more stable. Advantage here: only one model "
            "instead of two experts, so 10 GB less download and no model switch in the "
            "middle of the run. The only I2V model that additionally needs CLIP Vision, "
            "which describes the start image."
        ),
        "pros": [
            "One model instead of two experts — no switch in the middle of the run",
            "10 GB less download than Wan 2.2 I2V",
            "Apache-2.0",
        ],
        "cons": [
            "Beaten by Wan 2.2 I2V A14B in motion and anatomy",
            "~15 GB VRAM: no headroom at all, risk of offloading",
            "22.9 GB download",
            "Very slow — many minutes per clip",
            "Requires a start image",
        ],
    },
    # --------------------------------------------------------------- 3D
    "trellis2-4b": {
        "name": "TRELLIS.2-4B (PBR textures)",
        "best_for": "Meshes WITH textures — albedo, normal, roughness/metallic",
        "description": (
            "Microsoft's current image-to-3D model and the only one here that delivers "
            "real PBR materials: albedo, normal and roughness/metallic as bitmaps, not "
            "just vertex colors. That makes an asset game-ready without manual texturing. "
            "Runs in its own worker with six self-compiled CUDA extensions; MIT license, "
            "so commercially usable without restriction."
        ),
        "pros": [
            "Complete PBR textures instead of geometry only — saves the texturing step",
            "MIT license, no regional restrictions",
            "Much better mesh quality than TripoSG",
            "Texture resolution adjustable up to 4096²",
        ],
        "cons": [
            "~14 GB VRAM at 512³ — hardly any headroom on 16 GB, 1024³ is out of reach",
            "16.2 GB download plus a ~7 GB venv with compiled extensions",
            "Needs Visual Studio 2022 Build Tools; with VS 18 the compilation fails",
            "Slower than TripoSG",
        ],
    },
    "hunyuan3d-2.1": {
        "best_for": "Best local mesh quality — but check the license for the EU",
        "description": (
            "Latest Hunyuan3D version in ComfyUI format. The required nodes are present in "
            "this ComfyUI installation, so no separate worker process is needed — only the "
            "workflow builder in NV-AI is still missing."
        ),
        "pros": [
            "Best mesh quality achievable locally",
            "Nodes already present natively — no extra setup",
            "GLB export directly to Unity",
        ],
        "cons": [
            "Workflow builder in NV-AI is still missing",
            "Tencent license with regional restrictions — critical for the EU",
            "Not for a commercial game without a license review",
        ],
    },
    "triposg": {
        "best_for": "Image to mesh with a clean license — the commercial choice",
        "description": (
            "On par with Hunyuan3D in quality, but under the MIT license: commercially "
            "usable without restriction, no regional clauses. For a game sold from within "
            "the EU, the less problematic choice. Runs in its own worker process alongside "
            "ComfyUI, not inside it. Delivers GLB meshes from a single image."
        ),
        "pros": [
            "MIT license: no restrictions whatsoever, not even regional ones",
            "Mesh quality close to Hunyuan3D",
            "~10 GB VRAM, fits the card well",
            "GLB export goes straight to Unity or Blender",
        ],
        "cons": [
            "Separate worker process with its own venv (~7 GB of additional dependencies)",
            "Geometry only, no textures — those come from a separate step",
            "Topology is raw material and needs retopo for game assets",
        ],
    },
    "trellis-image-large": {
        "best_for": "Fast, tiny, MIT — good for volume and prototypes",
        "description": (
            "Microsoft's image-to-3D model under the MIT license. Generates meshes, "
            "Gaussian splats and radiance fields from an image. At just over 1.5 GB "
            "extremely compact and fast, slightly below TripoSG and Hunyuan3D in quality — "
            "but the most practical choice for many assets in a short time."
        ),
        "pros": [
            "MIT license, commercially unrestricted",
            "Very small (1.6 GB) and fast",
            "Also delivers Gaussian splats, not just meshes",
        ],
        "cons": [
            "Not usable yet: needs its own worker process",
            "Coarser than TripoSG and Hunyuan3D",
            "Installing the dependencies (nvdiffrast) is laborious on Windows",
        ],
    },
    "instantmesh": {
        "best_for": "Smallest commercial option, very fast",
        "description": (
            "Generates a mesh from an image via multi-view diffusion. Apache-2.0 and at "
            "1.4 GB the leanest option here. Behind TripoSG in quality, but often "
            "sufficient for simple props."
        ),
        "pros": [
            "Apache-2.0, no restrictions",
            "Only 1.4 GB, very fast",
        ],
        "cons": [
            "Not usable yet: needs its own worker process",
            "Much coarser meshes than TripoSG or Hunyuan3D",
            "Unreliable with complex shapes",
        ],
    },
    "hunyuan3d-2": {
        "best_for": "Image to 3D mesh — directly in ComfyUI, without an extra worker",
        "description": (
            "Generates a 3D mesh from a single image and exports it as GLB. Runs natively "
            "in this ComfyUI version, so no separate worker process is needed. Delivers "
            "the geometry; texturing is a separate step."
        ),
        "pros": [
            "Best mesh quality achievable locally on 16 GB",
            "Natively supported — no dependency hell",
            "GLB export goes straight to Unity",
        ],
        "cons": [
            "Tencent license with regional restrictions — check carefully for the EU",
            "Geometry only; texture is a separate pass",
            "Topology is raw material and needs retopo",
        ],
    },
    "hunyuan3d-2-mv-turbo": {
        "best_for": "Faster, and uses several views of the same object",
        "description": (
            "Turbo variant with fewer steps. Can combine several views of an object, "
            "which makes back sides much more plausible — useful if you have generated "
            "front/side/back as images beforehand."
        ),
        "pros": [
            "Faster than the standard variant",
            "Multiple views give more believable back sides",
        ],
        "cons": [
            "The same Tencent license issue",
            "Turbo costs some detail fidelity",
        ],
    },
    # ------------------------------------------------------- CONTROLNET
    "sd35-controlnet-depth": {
        "name": "SD 3.5 ControlNet — Depth",
        "best_for": "Vehicles and buildings: enforce silhouette and proportions from a template",
        "description": (
            "Takes a depth map as guidance and forces the image into its shape. Exactly "
            "the remedy for warped tanks and aircraft: instead of hoping the model guesses "
            "a Panzer IV correctly, you specify the silhouette.\n\n"
            "The depth map can come from Blender, from a rough blockout or from a "
            "three-view drawing. Pass it as a reference image with "
            "`preprocess=\"none\"` — NV-AI then processes it unchanged.\n\n"
            "Only for SD 3.5 Large. It gets tight on 16 GB: free VRAM beforehand."
        ),
        "pros": [
            "The most effective lever against deformed vehicles",
            "Commercially usable, not gated",
            "Lets go at the end (`controlnet_end`), details stay free",
        ],
        "cons": [
            "8.7 GB download",
            "An additional ~4.3 GB VRAM alongside the image model — tight on 16 GB",
            "Needs a depth map; NV-AI does not generate one itself",
            "SD 3.5 only, not for FLUX or Chroma",
        ],
    },
    "sd35-controlnet-canny": {
        "name": "SD 3.5 ControlNet — Edges",
        "best_for": "Template is a drawing, blueprint or photo",
        "description": (
            "Guides the image along edges. Handy when your template is already a line "
            "drawing — blueprint, technical drawing, concept sketch. NV-AI extracts the "
            "edges from a photo itself (`preprocess=\"canny\"`); no further model is "
            "needed for that.\n\n"
            "Edges are stricter than depth: the result follows the template very closely. "
            "Good for silhouette fidelity, too narrow for free interpretation."
        ),
        "pros": [
            "Edge detection is built in — no additional download",
            "Very accurate adoption of the template",
            "Commercially usable, not gated",
        ],
        "cons": [
            "8.7 GB download",
            "An additional ~4.3 GB VRAM — tight on 16 GB",
            "Stricter than depth: little leeway for the model",
            "SD 3.5 only",
        ],
    },
}

# Every size label used anywhere in catalog.py (German label -> English label),
# e.g. "1328 × 1328 — Qwen nativ, Objekte" -> "1328 × 1328 — Qwen native, objects".
SIZE_LABELS: dict[str, str] = {
    # QWEN21_SIZES
    "1536 × 1536 — 2,4 MP, Objekte": "1536 × 1536 — 2.4 MP, objects",
    "1344 × 1792 — 3:4, Figuren": "1344 × 1792 — 3:4, figures",
    "1792 × 1344 — 4:3, Fahrzeuge": "1792 × 1344 — 4:3, vehicles",
    "2048 × 2048 — Qwen nativ, maximal": "2048 × 2048 — Qwen native, maximum",
    # hfsearch.SD15_SIZES (models added from the Hugging Face search)
    "512 × 512 — SD 1.5 nativ": "512 × 512 — SD 1.5 native",
    "512 × 768 — Hochformat": "512 × 768 — portrait",
    "768 × 512 — Querformat": "768 × 512 — landscape",
    # QWEN_NATIVE_SIZES
    "1328 × 1328 — Qwen nativ, Objekte": "1328 × 1328 — Qwen native, objects",
    "1056 × 1584 — Qwen nativ 2:3, Figuren": "1056 × 1584 — Qwen native 2:3, figures",
    "1104 × 1472 — Qwen nativ 3:4": "1104 × 1472 — Qwen native 3:4",
    "1584 × 1056 — Qwen nativ 3:2, Fahrzeuge": "1584 × 1056 — Qwen native 3:2, vehicles",
    "1472 × 1104 — Qwen nativ 4:3": "1472 × 1104 — Qwen native 4:3",
    "1664 × 928 — Qwen nativ 16:9, Panorama": "1664 × 928 — Qwen native 16:9, panorama",
    "928 × 1664 — Qwen nativ 9:16": "928 × 1664 — Qwen native 9:16",
    # FLUX3_LARGE_SIZES
    "1152 × 1728 — 2 MP hochkant, Figuren mit Detail":
        "1152 × 1728 — 2 MP portrait, detailed figures",
    "1440 × 1440 — 2 MP, Objekte mit Detail": "1440 × 1440 — 2 MP, detailed objects",
    "1728 × 1152 — 2 MP quer, Fahrzeuge mit Detail":
        "1728 × 1152 — 2 MP landscape, detailed vehicles",
    "2048 × 2048 — 4 MP, maximal": "2048 × 2048 — 4 MP, maximum",
}
