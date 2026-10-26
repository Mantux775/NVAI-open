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
KREA2_PROMPT_HINT = (
    "Full English sentences, style first: medium, then the subject with material and light, last the "
    "background. State the framing explicitly (\"medium shot from the waist up, his whole head inside "
    "the frame\"), otherwise Krea moves what the prompt stresses into view and crops other parts. Krea 2 "
    "is trained on detailed descriptions; expand a few words with \"Expand prompt\" first. The negative "
    "prompt has no effect here (cfg 1)."
)
KREA2_LICENSE_WARNING = (
    "Krea 2 Community License: commercial use only below US$1 million in annual revenue (including "
    "affiliated companies), a content filter or a review of every image by hand is required, label as "
    "AI-generated where required by law. Krea can terminate the license with 30 days' notice."
)
_LICENSE_CON_KREA2 = "Community license: commercial use only below US$1 million revenue, review obligation, can be terminated"
MOSS_IMAGE_PROMPT_HINT = (
    "MOSS-Image was trained on image descriptions: describe what the finished image looks like, not what to "
    "do. Medium and subject first, then setting and composition, then light and colors. Put text in quotation "
    "marks, word for word, with position, size and typeface; set line breaks yourself. MOSS-Image expands short "
    "prompts first with its own text encoder (can be switched off). Layout: a JSON with \"summary\" and "
    "\"items\" as the prompt, then without expansion. The negative prompt works (cfg 3)."
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

KANDINSKY5_VAE_WARNING = (
    "The model is MIT-licensed, but the VAE comes from HunyuanVideo (Tencent Hunyuan Community "
    "License). According to Tencent it does not apply in the EU, the UK and South Korea — check "
    "before commercial use there."
)

_LTX25_WARNING = ("LTX-2 Community License: free only below US$10 million annual revenue; the watermark "
                  "must not be removed. Gated repo — accept the license on Hugging Face and store a "
                  "token. For DFR the detail IC-LoRA needs its own access.")

_GATED_LORA_EN = ("LTX-2 Community License. Gated repo — accept its license on Hugging Face separately "
                  "(its own access, besides LTX-2.5).")
_NO_LICENSE_EN = "No license stated in the repo: ask the author before any commercial use."

_LTX25_WAYS = (
    "Ways in NVAI-open:\n"
    "• Text to video or with a start image: two stages, first at half resolution, then upscaled "
    "and refined.\n"
    "• Start and end image: a transition between two images. With \"Loop\" the start image is also "
    "the end image, for seamless loops.\n"
    "• Best quality (DFR, Diffusion Fidelity Rendering): detail keyframes and a detail IC-LoRA, "
    "optionally at 48 fps.\n"
    "• Automatic length: a small extra head estimates the duration from the described action.\n"
    "• Given sound: an existing sound, such as music from Stable Audio 3, stays as it is and the picture "
    "follows it.\n"
    "• Several shots (multi-shot): write the cuts out in the prompt.\n"
    "• Slow motion: together with Lightricks' Slow Motion LoRA.\n"
)

# Die Formatnamen uebersetzt SIZE_LABELS (registry.features_for).
_LTX25_FEATURES_EN = {
    "prompt_hint": (
        "One paragraph in the present tense, 4 to 8 sentences: the shot, setting and light, the "
        "action from start to end with verbs, the people, the camera movement, last the sound. "
        "Spoken lines in quotation marks. Several shots: write every cut out (\"A hard cut "
        "transitions to …\"), 2 to 4 shots."),
}


_AMD_NOTE = ("Not tested on AMD yet (feedback via “Report a problem” helps). On NVIDIA cards the NVFP4 or INT8 "
             "version is the better choice.")

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
    "qwen-image-2512-int8": {
        "name": "Qwen-Image-2512 (INT8, for RTX 20/30/40)",
        "best_for": "Qwen-Image-2512 on cards without FP4 (RTX 20/30/40)",
        "features": {
            "prompt_hint": QWEN_PROMPT_HINT + " Without a negative prompt of your own, the "
                           "one from Qwen's model card applies.",
        },
        "description": (
            "The same model as `qwen-image-2512-nvfp4` (50 steps, cfg 4), but in INT8 instead of "
            "NVFP4. INT8 is computed in hardware on every NVIDIA card from RTX 20 onward; NVFP4 only "
            "on RTX 50, on older cards it is unpacked layer by layer and is much slower.\n\n"
            "Quantized with Comfy-Org's tool comfy-quants (int8 tensorwise with ConvRot), runs "
            "without a custom node. The file is 20.6 GB; on cards with less memory ComfyUI streams "
            "parts from system memory.\n\n"
            "Measured on an RTX 5060 Ti (16 GB) at 1024 × 1024: 119 s per image, 132 s with "
            "loading (NVFP4 there 101 and 108 s). The test crate came out just as well: lettering "
            "exact, rope handles through drilled holes.\n\n"
            "Measured on an RTX 4060 with 8 GB (on a riser, PCIe 3.0 x4): 653 s including loading, the "
            "NVFP4 version 1095 s there. Neither fits into 8 GB, but INT8 is computed in hardware. "
            "Lettering and rope handles came out clean here too.\n\n"
            "Everything else — prompt rules, negative prompt, native sizes — as with the NVFP4 version."
        ),
        "pros": [
            "Computed in hardware on RTX 20/30/40",
            "RTX 4060 (8 GB): 653 instead of 1095 s with NVFP4",
            "Negative prompt works (cfg 4.0)",
            "Apache-2.0",
            "Shares text encoder and VAE with the NVFP4 versions",
        ],
        "cons": [
            "20.6 GB instead of 14.9 GB: on 16 GB and less ComfyUI streams parts in",
            "On RTX 50 the NVFP4 version is the faster choice",
            "Community upload, not an official version by Qwen or Comfy-Org",
        ],
    },
    "krea2-turbo-nvfp4": {
        "name": "Krea 2 Turbo (NVFP4, 8 steps)",
        "warning": KREA2_LICENSE_WARNING,
        "best_for": "Photographic, aesthetic images with little AI look — third choice after Qwen and FLUX 3",
        "features": {"prompt_hint": KREA2_PROMPT_HINT},
        "description": (
            "Krea 2 by Krea.ai (June 2026): a diffusion transformer with 12 billion parameters, released "
            "with open weights as Raw (for fine-tuning) and Turbo (distilled, 8 steps, cfg 1). Krea is known "
            "for images with little AI look. The text encoder is Qwen3-VL-4B, the same as FLUX 3's, and the "
            "VAE is Qwen-Image's; if you have one of those models, only 7.7 GB remain to download.\n\n"
            "Measured on the RTX 5060 Ti (24 Oct): about 20 s per 1 MP image, 41 s for the first run including "
            "loading, 1408 × 1408 (2 MP) in 37 s; in the same comparison with the same prompt and seed "
            "Qwen-Image-2512 took 109–160 s and FLUX 3 31–36 s. Krea looked the most photographic: natural "
            "hands and faces, letter-perfect crate lettering, the ropes pass through drilled holes (but the "
            "crate came without a lid, which the prompt did not mention), and the standing figure has both "
            "boots in the frame. For the old fisherman, whose prompt stresses his hands, the head was cut off "
            "at the top in three of three images; with \"medium shot from the waist up, his whole head inside "
            "the frame\" it was in the frame in two of two.\n\n"
            "Style reference (since 0.5.10): with ostris' optional LoRA (0.46 GB, Krea 2 license; \"Download extras\" under \"Models\" fetches it) Krea 2 takes one or two images as a style template. Technique, colors and light come from the image, the content from the prompt. Measured: a lighthouse with a watercolor or a woodcut template clearly in their style, 41–48 instead of 24 s; with both templates 71 s, and the first one dominated almost completely.\n\n"
            "Output from 1 to 2 MP. The negative prompt has no effect (cfg 1). Krea's template expands short "
            "prompts first; here \"Expand prompt\" does that.\n\n"
            "License: Krea 2 Community License — see warning."
        ),
        "pros": [
            "Photographic look, little AI smoothness",
            "Measured about 20 s per image (1 MP), 2 MP in 37 s",
            "Letter-perfect text in the image",
            "Style reference with 1–2 images (optional LoRA, 0.46 GB)",
            "8 steps, NVFP4 only 7.7 GB",
            "Shares text encoder and VAE with FLUX 3 and Qwen-Image",
        ],
        "cons": [
            _LICENSE_CON_KREA2,
            "State the framing explicitly, otherwise it crops (fisherman: head cut off 3 of 3)",
            "Negative prompt has no effect (cfg 1)",
            "Reference images only as a style template; for editing, FLUX 3 remains the choice",
        ],
    },
    "krea2-turbo-int8": {
        "name": "Krea 2 Turbo (INT8, for RTX 20/30/40)",
        "warning": KREA2_LICENSE_WARNING,
        "best_for": "Krea 2 on cards without FP4 (RTX 20/30/40)",
        "features": {"prompt_hint": KREA2_PROMPT_HINT},
        "description": (
            "The same model as `krea2-turbo-nvfp4`, in Comfy-Org's INT8 version (ConvRot), which is "
            "computed in hardware on every NVIDIA card from RTX 20 onward. 13.5 GB; on cards with less "
            "memory ComfyUI streams parts from system memory. The prompt hints of the NVFP4 version apply "
            "here too.\n\n"
            "Measured on an RTX 4060 with 8 GB (on a riser, PCIe 3.0 x4), 1024 × 1024: 193 s for the first "
            "image, then 82 s, the image as with NVFP4 (letter-perfect). The NVFP4 version took 46 s there "
            "including loading: at 7.7 GB it fits into the graphics memory, while the INT8 version has to be "
            "streamed over the slow connection. On a normal connection (PCIe 4.0 x8, an RTX 40 without FP4 "
            "emulated), INT8 was twice as fast instead: 13 instead of 25 s with 8 GB, 12 instead of 25 s with "
            "16 GB. NVAI-open therefore recommends INT8 and NVFP4 only on a slow connection.\n\n"
            "License: Krea 2 Community License — see warning."
        ),
        "pros": [
            "Computed in hardware on RTX 20/30/40",
            "Shares text encoder and VAE with FLUX 3 and Qwen-Image",
        ],
        "cons": [
            _LICENSE_CON_KREA2,
            "On RTX 50 the NVFP4 version is the faster choice",
            "On a slow connection (PCIe 3.0 x4) slower than NVFP4 (RTX 4060 on a riser: 82 instead of 46 s)",
        ],
    },
    "moss-image-sft-int8": {
        "name": "MOSS-Image SFT (INT8, 50 steps)",
        "best_for": "Text and layout in the image, posters and graphics — free to use (Apache-2.0)",
        "features": {"prompt_hint": MOSS_IMAGE_PROMPT_HINT},
        "description": (
            "MOSS-Image by OpenMOSS (16 Oct 2026): a diffusion transformer with 5 billion parameters under "
            "Apache-2.0, trained on detailed image descriptions. The text encoder is Qwen3.5-9B (W4A8), together "
            "with the small FLUX.2 VAE, which is Apache-2.0 as well. NVAI-open first expands a short prompt into a "
            "full description with MOSS's own text encoder (system prompt from ComfyUI's template, can be switched "
            "off); it is stored in the asset under \"caption\".\n\n"
            "Measured on the RTX 5060 Ti (25 Oct) with OpenMOSS's settings (50 steps, cfg 3, the default): about "
            "51 s per 1 MP image, plus about 11 s for the expansion the first time; with the 25 steps of ComfyUI's "
            "template 28 s. Text came out letter-perfect in every test (\"MUNITION 7,92\", the poster \"ALPENGLOW\" "
            "with \"SINCE 1928\"), the soldier stood in the frame with both boots, the fisherman kept his head in "
            "the frame. With 50 steps the crate's rope handles passed through drilled holes in three of three "
            "images, with 25 steps in two of three; once the lid was missing (not named in the prompt).\n\n"
            "MOSS-Image is not available on the Mac (no MLX version)."
        ),
        "pros": [
            "Apache-2.0: images can be sold without a revenue limit or review obligation",
            "Text in the image in English and Chinese, long texts too",
            "Layout as JSON: where each object and each line of text goes",
            "Own prompt expansion (can be switched off), the negative prompt works",
        ],
        "cons": [
            "Text to image only: no reference images, no editing, no mask",
            "Qwen3.5-9B text encoder: 7.3 GB extra (not the same as FLUX 3's upsampler)",
            "Not available on the Mac (no MLX version)",
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
            "description is stored in the asset under \"caption\". NVAI-open takes repeated "
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
    "hidream-o1-dev-fp8": {
        "name": "HiDream-O1-Image Dev (fp8, 28 steps)",
        "best_for": "Large images (4 MP), editing with reference images — MIT license",
        "description": (
            "HiDream.ai, May 2026. 8 billion parameters, works directly in pixel space: text "
            "encoder and image output live in a single file, there is no separate VAE. Trained at "
            "about 4 megapixels (2048 × 2048 and similar sizes); according to the maker, smaller "
            "images get noticeably worse.\n\n"
            "The Dev version is distilled: 28 steps at cfg 1, so the negative prompt has no effect. "
            "Reference images are attached to the prompt (editing, combining subjects).\n\n"
            "Measured on an RTX 5060 Ti (fp8, ComfyUI 0.42.1) at 1728 × 2304: 41 s, 87 s for the first "
            "image including the ComfyUI start. In the test: full figure with both boots, clean hands; "
            "the \"plain grey\" background became a mottled cloth. Editing with a reference image "
            "(104 s) got the change right but washed out the colors and darkened the background — "
            "for editing, Boogu-Image Edit is better.\n\n"
            "Values from ComfyUI's template image_hidream_o1_dev.json. MIT license."
        ),
        "pros": ["MIT license, free for commercial use", "One file, 8 GB",
                 "Reference images for editing and combining", "Native 4 megapixels"],
        "cons": ["Noticeably worse below 4 megapixels (per the maker)",
                 "Negative prompt has no effect (distilled, cfg 1)", "Content filtering not documented"],
        "features": {"prompt_hint": ("Full sentences: style, subject, material, light, background. For "
                                     "edits, say what changes and what stays. Choose a size around "
                                     "4 megapixels; below that, quality suffers.")},
    },
    "hidream-o1-fp8": {
        "name": "HiDream-O1-Image (fp8, 40 steps)",
        "best_for": "Full quality with negative prompt, 4 MP — slower than Dev",
        "description": (
            "The full, non-distilled version of HiDream-O1-Image: 40 steps at cfg 5, the negative "
            "prompt works. A dedicated node smooths the seams between image patches. Otherwise like "
            "Dev: pixel space, one file, about 4 megapixels, reference images.\n\n"
            "Measured on an RTX 5060 Ti at 1728 × 2304: 142 s. The template uses the sampler "
            "dpmpp_2m_sde_gpu; with the fp8 file the background broke into blocks, so NVAI-open uses "
            "euler (clean).\n\n"
            "Values from ComfyUI's template image_hidream_o1.json, sampler changed. MIT license."
        ),
        "pros": ["MIT license", "Negative prompt works (cfg 5)", "Reference images", "Native 4 megapixels"],
        "cons": ["40 steps at 4 MP: much slower than Dev", "Content filtering not documented"],
        "features": {"prompt_hint": ("Full sentences: style, subject, material, light, background. The "
                                     "negative prompt works (cfg 5). Choose a size around 4 megapixels.")},
    },
    "boogu-image-turbo-nvfp4": {
        "name": "Boogu-Image 0.1 Turbo (NVFP4, 4 steps)",
        "best_for": "Fast drafts in 4 steps — Apache-2.0",
        "description": (
            "Boogu, June 2026 (research project, version 0.1). 10 billion parameters with Qwen3-VL-8B "
            "as the text encoder. The Turbo version runs 4 steps at cfg 1; the negative prompt has no "
            "effect. NVAI-open uses the corrected \"hotfix\" version.\n\n"
            "Measured on an RTX 5060 Ti at 832 × 1216: 9.8 s, 17 s for the first image. In the test: "
            "full figure, plain grey background as asked.\n\n"
            "Values from ComfyUI's template image_boogu_image_0_1_turbo_t2i.json. Apache-2.0."
        ),
        "pros": ["Apache-2.0", "4 steps", "NVFP4: model only 5.8 GB"],
        "cons": ["Version 0.1, a research project per the maker", "Negative prompt has no effect (cfg 1)",
                 "Text encoder 10.6 GB", "Content filtering not documented"],
        "features": {"prompt_hint": "Full sentences: style, subject, material, light, background."},
    },
    "boogu-image-nvfp4": {
        "name": "Boogu-Image 0.1 Base (NVFP4, 25 steps)",
        "best_for": "Full quality with negative prompt — Apache-2.0",
        "description": (
            "The non-distilled Base version of Boogu-Image 0.1: 25 steps at cfg 3.5, the negative "
            "prompt works. Shares text encoder and VAE with Turbo and Edit.\n\n"
            "Values as in ComfyUI's template image_boogu_image_0_1_edit.json (there is no separate "
            "text-to-image template for Base). Measured on an RTX 5060 Ti at 832 × 1216: 66 s. "
            "Apache-2.0."
        ),
        "pros": ["Apache-2.0", "Negative prompt works (cfg 3.5)"],
        "cons": ["Version 0.1, a research project per the maker", "Content filtering not documented"],
        "features": {"prompt_hint": "Full sentences: style, subject, material, light, background. The negative prompt works."},
    },
    "boogu-image-edit-nvfp4": {
        "name": "Boogu-Image 0.1 Edit (NVFP4, editing)",
        "best_for": "Change an image by instruction — Apache-2.0",
        "description": (
            "The editing version of Boogu-Image 0.1: one reference image plus an instruction "
            "(\"remove the hat\", \"make it winter\"). The image is used twice: as visual "
            "understanding for the instruction and as a reference for the content. 25 steps, cfg 3.5.\n\n"
            "Measured on an RTX 5060 Ti at 832 × 1216: about 147 s. In the test (\"replace the pith "
            "helmet with a red baseball cap\") only the hat changed; face, outfit, satchel, boots "
            "and background stayed the same.\n\n"
            "Values from ComfyUI's template image_boogu_image_0_1_edit.json. Apache-2.0."
        ),
        "pros": ["Apache-2.0 alternative to editing with FLUX 3", "Instructions in plain language"],
        "cons": ["Needs a reference image", "Version 0.1, a research project per the maker",
                 "Content filtering not documented"],
        "features": {"prompt_hint": ("Say what should change and what should stay. Best with one "
                                     "reference image; several are allowed.")},
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
            "Only text-to-image in NVAI-open; the edit variant is not integrated",
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
    "stable-audio-3-medium": {
        "best_for": "Instrumental game music, ambience and tension beds",
        "description": (
            "Stability AI's 2026 music model, distilled to 8 steps. Generates instrumental "
            "pieces at 44.1 kHz stereo, in NVAI-open up to 5 minutes (according to Stability the model "
            "can do up to 6:20), trained only on licensed data according to Stability. No vocals "
            "and no lyrics; a choir comes through at most "
            "as a wordless texture. Describe genre, instruments, mood and tempo, as a sentence "
            "or as a list."
        ),
        "pros": [
            "Trained only on licensed data according to Stability",
            "Up to 5 minutes in one go, 44.1 kHz stereo; measured 60 s in 9–12 s, 300 s in 64 s",
            "Distilled: 8 steps, CFG 1",
        ],
        "cons": [
            "No vocals, no lyrics",
            "Community License with a USD 1 million revenue cap; the text encoder (T5Gemma) is under the Gemma terms",
            "Long pieces need a lot of graphics memory: 300 s almost filled 16 GB (60 s: 9.7 GB)",
            "New in NVAI-open, not much experience yet",
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
    "ltx25-distilled-nvfp4": {
        "name": "LTX-2.5 (NVFP4, distilled, with sound)",
        "warning": _LTX25_WARNING,
        "best_for": "The recommended video model: video with sound from text, a start image, or a start and end image",
        "description": (
            "Lightricks, August 2026. 22 billion parameters, generates picture and sound in one pass: "
            "noises, music and speech that fit the scene; spoken lines go into the prompt in quotation "
            "marks. The text encoder is Gemma 4 12B (INT8). Model and encoder do not fit into 16 GB at "
            "the same time; ComfyUI offloads.\n\n"
            + _LTX25_WAYS + "\n"
            "Measured on an RTX 5060 Ti (16 GB, 24 fps, 1280 × 704, with sound): 5 s from text in 93 s "
            "(first run with loading 122 s), with a start image 109 s, start and end image 154 s, a 4 s "
            "loop 125 s; 1920 × 1088 in 251 s; 20 s to a given sound at 1024 × 576 in 302 s. Graphics "
            "memory is almost full. Sounds described as quiet (\"crackles softly\") come out very "
            "quiet; name loud sources explicitly.\n\n"
            "Output is MP4 with sound. Graphs after ComfyUI's templates video_ltx2_5_t2v, _i2v, _flf2v "
            "and _dfr_i2v."
        ),
        "pros": ["Video with matching sound", "Text, start image, start and end image, loop",
                 "DFR for more detail, optionally at 48 fps",
                 "Automatic length, given sound, multi-shot, slow motion",
                 "NVFP4: computed in hardware on RTX 50", "License allows the EU"],
        "cons": ["37.5 GB download", "Free only below US$10 million revenue",
                 "DFR needs its own access on Hugging Face (detail IC-LoRA)",
                 "Width and height are rounded to multiples of 64", "Content filtering not documented"],
        "features": _LTX25_FEATURES_EN,
    },
    "ltx25-distilled-int8": {
        "name": "LTX-2.5 (INT8, distilled, with sound)",
        "warning": _LTX25_WARNING,
        "best_for": "The same LTX-2.5 for RTX 20/30/40 (INT8 in hardware) and AMD Radeon",
        "description": (
            "The same model in the INT8 version that ComfyUI's own LTX-2.5 templates use (INT8 with "
            "ConvRot). Meant for cards without FP4 units: RTX 20, 30 and 40 compute INT8 in hardware, "
            "NVFP4 they would have to unpack layer by layer.\n\n"
            + _LTX25_WAYS + "\n"
            "On an RTX 50 the NVFP4 version is smaller and the right one; this version has not been "
            "measured in NVAI-open yet."
        ),
        "pros": ["Everything the NVFP4 version can do", "INT8 runs in hardware from RTX 20",
                 "License allows the EU"],
        "cons": ["40.3 GB download", "Not measured in NVAI-open yet",
                 "Free only below US$10 million revenue",
                 "DFR needs its own access on Hugging Face (detail IC-LoRA)"],
        "features": _LTX25_FEATURES_EN,
    },
    # Empfohlene LoRAs fuer LTX-2.5 (catalog.LORA_MODELS)
    "lora-ltx-2.5-22b-lora-cinemagraph-ltx-2.5-22b-lora-cinemagraph-0.9": {
        "warning": _GATED_LORA_EN,
        "best_for": "Living still image: one element moves, the rest stays still",
        "description": ("Official LoRA by Lightricks for LTX-2.5. Turns a start image into a cinemagraph: "
                        "one element moves (water, smoke, hair, light), everything else stays still. "
                        "Only works together with \"Loop\", which NVAI-open switches on when you activate "
                        "it; the result is a seamless loop, for menu and loading screens for example. Put "
                        "the trigger CINEMAGRAPH_MOTION into the prompt, strength 1.0 to 1.2. Measured (a "
                        "king in front of flickering torches, 4 s): with a loop 6 % of the picture moved "
                        "and the face stood still; a loop without the LoRA 28 %; without a loop 82–84 %, "
                        "also at strength 1.2, because the camera pushed in."),
        "features": {"tested": "Tested on LTX-2.5: only works with \"Loop\" (6 % instead of 28 % of the "
                               "picture moving, the face still)"},
    },
    "lora-ltx-2.5-22b-lora-slow-motion-control-ltx-2.5-22b-lora-slow-motion-control-1.0": {
        "warning": _GATED_LORA_EN,
        "best_for": "Slow motion 2× to 40× at the same playback rate",
        "description": ("Official LoRA by Lightricks for LTX-2.5. With a start image and the \"Slow "
                        "motion\" setting (0.5 = 2×, 0.2 = 5×, 0.1 = 10× slower) the motion runs slower "
                        "while playback stays at 24 fps. No trigger word, and do not write \"slow "
                        "motion\" into the prompt. Strength 1.0. Measured with Lightricks' settings (a wave "
                        "against rocks, 1920 × 1088, 5 s, 0.2): the spray fell over the whole 5 s instead of "
                        "about 1.5 s, the droplets stayed sharp. Without the LoRA the spray stood almost "
                        "still as a milky veil. At 1280 × 704 and 0.25 the effect was weaker."),
        "features": {"tested": "Tested on LTX-2.5 (1080p, slow motion 0.2): the spray falls over 5 s instead "
                               "of 1.5 s, droplets sharp; without the LoRA only a milky, frozen veil"},
    },
    "lora-ltx-2.3-transition-lora-ltx2.3-transition": {
        "best_for": "Transitions and transformations between a start and an end image",
        "description": ("Trained for LTX-2.3 on transitions between the first and the last image: "
                        "transformations, scene and style changes. According to the author it also "
                        "helps with text and start images. Strength 1.0. Tested with LTX-2.5 in "
                        "NVAI-open (village square from day to night, start and end image): hardly any "
                        "difference from no LoRA."),
        "features": {"tested": "Tested on LTX-2.5: hardly any difference from no LoRA for day to night"},
    },
    "lora-ltx_2.3_crisp_enhance_style_lora-ltx2.3_crisp_enhance": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Sharper: more micro-detail, edges and contrast",
        "description": ("For LTX-2.3. Raises sharpness, edges and contrast. Tested with LTX-2.3 in "
                        "NVAI-open: clearly sharper, but it changed the composition."),
    },
    "lora-ltx_2.3_fantasy_anime_style_lora-fantasy_anime": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Fantasy anime with cel shading",
        "description": ("For LTX-2.3. Fantasy anime illustration with cel shading; according to the "
                        "author trained without existing characters. Trigger f4nt4sy4n1m6, strength 1.0. "
                        "Tested with LTX-2.5 in NVAI-open: a clear anime look with cel shading."),
        "features": {"tested": "Tested on LTX-2.5: a clear anime look"},
    },
    "lora-ltx_2.3_fantasy_painterly_style_lora-fantasy_painterly": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Painted fantasy scenes with visible brush strokes",
        "description": ("For LTX-2.3. Fantasy as if painted in oil: brush strokes, layers of paint, "
                        "glowing light. Trigger D4rkP41nt3r. Tested with LTX-2.5 in NVAI-open: clearly "
                        "painted, darker colors."),
        "features": {"tested": "Tested on LTX-2.5: clearly painted"},
    },
    "lora-ltx_2.3_clay_mation_style_lora-claymation": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Clay figures and stop-motion dioramas",
        "description": ("For LTX-2.3. Characters and places shaped as if from clay, with fingerprints "
                        "and miniature sets. Trigger claymation style. Tested with LTX-2.5 in NVAI-open: "
                        "only hinted at (a felt and miniature look), also at strength 1.4."),
        "features": {"tested": "Tested on LTX-2.5: only hinted at, also at strength 1.4"},
    },
    "lora-ltx_2.3_paper_cut_out_style_lora-papercutoutstyle": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Paper cut-out dioramas like from a picture book",
        "description": ("For LTX-2.3. Everything looks cut and folded from layers of paper. Trigger "
                        "Pap3rCut0u7. Tested with LTX-2.5 in NVAI-open: hardly visible at strength 1.0, a "
                        "flat paper cut-out look at 1.5."),
        "features": {"tested": "Tested on LTX-2.5: only clear at strength 1.5"},
    },
    "lora-ltx_2.3_cinematic_sci-fi-cyberpunk_style_lora-cinematic_sci-fi-cyberpunk": {
        "license": "not stated",
        "warning": _NO_LICENSE_EN,
        "best_for": "Neon noir and cyberpunk cities",
        "description": ("For LTX-2.3. A realistic cyberpunk look: neon light, wet streets, high tech. "
                        "Trigger C6b4rP8nk."),
    },
    "lora-ltx2.3-audio-reactive-lora-ltx2.3_audio_reactive_lora_v2": {
        "best_for": "Visualizers and music videos that react to the beat",
        "description": ("For LTX-2.3, version 2. Shapes, particles and light pulse to the beat of a "
                        "given sound. Best with a start image and \"Given sound\", strength 1.0 to 1.5, "
                        "5 to 15 seconds. Tested with LTX-2.5 in NVAI-open: even without the LoRA the "
                        "visualizer pulsed to the given sound; with it, brightness followed the loudness "
                        "a little more closely (correlation 0.23 instead of 0.09) and the picture got "
                        "softer."),
        "features": {"tested": "Tested on LTX-2.5: the picture follows the sound a little more closely; "
                               "LTX-2.5 pulses without it too"},
    },
    "ltx23-nvfp4": {
        "name": "LTX-2.3 (NVFP4, with sound)",
        "warning": "LTX-2 Community License: free only below US$10 million annual revenue.",
        "best_for": "Video with sound; the base of most community LoRAs and finetunes for LTX",
        "description": (
            "Lightricks, the predecessor of LTX-2.5 with the same architecture (22 billion "
            "parameters, picture and sound in one pass). There are far more community extensions for "
            "2.3 than for 2.5: LoRAs for styles, characters and motion, and finetunes without content "
            "filtering. This is the right base for them.\n\n"
            "NVAI-open works like ComfyUI's template video_ltx2_3_t2v.json: dev checkpoint in NVFP4 plus "
            "the distilled LoRA (strength 0.5), two stages with fixed sigmas, text encoder Gemma 3 12B "
            "(fp4). With a start image it is image to video. Measured on an RTX 5060 Ti, 97 frames "
            "(4 s) at 24 fps: 1280 × 704 with sound in 101 s, image to video 448 × 832 in 65 s. In the "
            "test a blacksmith with hammer sound; with a start image the figure stayed intact."
        ),
        "pros": ["Video with matching sound", "Text and image to video in one model",
                 "Largest choice of community LoRAs for LTX", "Not a gated repo"],
        "cons": ["35 GB download", "Free only below US$10 million revenue",
                 "The newer LTX-2.5 is better at the same size",
                 "Width and height are rounded to multiples of 64"],
    },
    "kandinsky5-lite-t2v": {
        "name": "Kandinsky 5.0 Video Lite T2V (2B)",
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Small MIT-licensed video model, 5 s at 768 × 512",
        "description": (
            "Kandinsky Lab (Sber), 2 billion parameters, MIT license. Text encoders Qwen2.5-VL 7B and "
            "CLIP-L, the VAE comes from HunyuanVideo. Trained for 5 s: 121 frames at 24 fps in "
            "768 × 512 (maker), no longer clips.\n\n"
            "Values from ComfyUI's template video_kandinsky5_t2v.json: 50 steps, cfg 5, "
            "euler_ancestral, beta, shift 5. The text encoder is the same as Qwen-Image's and is "
            "stored only once. Measured on an RTX 5060 Ti: 5 s of video at 768 × 512 in 26 minutes "
            "(1578 s) — use the distilled version for drafts."
        ),
        "pros": ["MIT license for the model", "Only 2 billion parameters",
                 "Text encoder shared with Qwen-Image", "Negative prompt works (cfg 5)"],
        "cons": ["VAE under Tencent's license", "50 steps", "5 s at most", "Content filtering not documented"],
    },
    "kandinsky5-lite-t2v-distilled": {
        "name": "Kandinsky 5.0 Video Lite T2V, distilled (16 steps)",
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Fast video drafts with Kandinsky",
        "description": (
            "The same Kandinsky 5.0 Lite, distilled to 16 steps without CFG. According to the model "
            "card 35 s instead of 77 s for 5 s of video on an H100. NVAI-open uses 16 steps and cfg 1; the "
            "negative prompt has no effect then. Measured on an RTX 5060 Ti: 5 s of video (121 "
            "frames, 768 × 512) in about 300 s. In the test a blacksmith with a coherent hammer "
            "motion and glowing metal."
        ),
        "pros": ["About three times fewer steps", "MIT license for the model"],
        "cons": ["VAE under Tencent's license", "Negative prompt has no effect (cfg 1)", "5 s at most"],
    },
    "kandinsky5-lite-i2v": {
        "name": "Kandinsky 5.0 Video Lite I2V (2B)",
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Animate a still image with a small model",
        "description": (
            "Image-to-video version of Kandinsky 5.0 Lite. The start image is cropped to the chosen "
            "size and put back as the first frame after sampling, as in ComfyUI's template "
            "video_kandinsky5_i2v.json. A start image is required. Measured on an RTX 5060 Ti: 5 s at "
            "768 × 512 in 27 minutes (1617 s). In landscape it kept the scene and followed the "
            "instruction; in portrait 512 × 768 the video jumped to a close-up after the first frame — "
            "use 768 × 512 only."
        ),
        "pros": ["MIT license for the model", "The start image stays exactly as the first frame"],
        "cons": ["VAE under Tencent's license", "Needs a start image", "Only reliable in landscape 768 × 512",
                 "27 minutes for 5 s"],
    },
    "mochi-1-preview-fp8": {
        "name": "Mochi 1 preview (fp8)",
        "best_for": "Apache-licensed text to video with smooth motion",
        "description": (
            "Genmo, 10 billion parameters, Apache-2.0. Strong at motion and prompt adherence according "
            "to the maker, made for 480p (848 × 480) at 30 fps. Text encoder T5-XXL (shared with "
            "Chroma).\n\n"
            "NVAI-open works like ComfyUI's Mochi example: 30 steps, cfg 4.5, euler. Frames are rounded to "
            "6n+1, the VAE decodes in tiles. Measured on an RTX 5060 Ti: 49 frames at 848 × 480 in "
            "351 s including loading. In the test a fox running cleanly through snow, with a sideways "
            "tracking shot."
        ),
        "pros": ["Apache-2.0, commercial use too", "Negative prompt works", "Text only, no license conditions"],
        "cons": ["Text to video only", "Preview from 2024, no successor",
                 "NSFW content limited according to the model card"],
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
            "workflow builder in NVAI-open is still missing."
        ),
        "pros": [
            "Best mesh quality achievable locally",
            "Nodes already present natively — no extra setup",
            "GLB export directly to Unity",
        ],
        "cons": [
            "Workflow builder in NVAI-open is still missing",
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
            "`preprocess=\"none\"` — NVAI-open then processes it unchanged.\n\n"
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
            "Needs a depth map; NVAI-open does not generate one itself",
            "SD 3.5 only, not for FLUX or Chroma",
        ],
    },
    "sd35-controlnet-canny": {
        "name": "SD 3.5 ControlNet — Edges",
        "best_for": "Template is a drawing, blueprint or photo",
        "description": (
            "Guides the image along edges. Handy when your template is already a line "
            "drawing — blueprint, technical drawing, concept sketch. NVAI-open extracts the "
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
    "seedvr2-7b-nvfp4": {
        "name": "SeedVR2 7B (NVFP4, sharpen and enlarge)",
        "best_for": "Sharpen, denoise and enlarge old photos after restoring them",
        "description": (
            "SeedVR2 by ByteDance (Apache-2.0): a diffusion model that restores images and videos in a "
            "single step. It removes noise, film grain, blur and compression artifacts and enlarges the "
            "image, without reinventing its content the way an image generator would.\n\n"
            "In NVAI-open it is the last step of \"Restore photo\": first FLUX 3 removes scratches and "
            "stains, then it colorizes on request, then SeedVR2 sharpens and enlarges. It also works on its "
            "own, for example for a small, noisy scan.\n\n"
            "The NVFP4 version is computed in hardware on RTX 50; older cards get INT8."
        ),
        "pros": [
            "Apache-2.0, free for commercial use",
            "One step: cleans up noise, grain and blur and enlarges at the same time",
            "Runs natively in ComfyUI, no extension needed",
        ],
        "cons": [
            "Does not repair scratches, tears or stains – \"Remove damage\" with FLUX 3 does that",
            "Invents fine detail (skin, fabric) at strong enlargement that was not in the original",
        ],
    },
    "seedvr2-7b-int8": {
        "name": "SeedVR2 7B (INT8, for RTX 20/30/40)",
        "best_for": "SeedVR2 on cards without FP4 (RTX 20/30/40)",
        "description": (
            "The same model as `seedvr2-7b-nvfp4` in Comfy-Org's INT8 version (ConvRot), computed in "
            "hardware from RTX 20 onward; ComfyUI's template uses it too. Not measured on this card."
        ),
        "pros": [
            "Apache-2.0, free for commercial use",
            "One step: cleans up noise, grain and blur and enlarges at the same time",
            "Runs natively in ComfyUI, no extension needed",
        ],
        "cons": [
            "Does not repair scratches, tears or stains – \"Remove damage\" with FLUX 3 does that",
            "Invents fine detail (skin, fabric) at strong enlargement that was not in the original",
            "On RTX 50 the NVFP4 version is the right one",
        ],
    },
    "seedvr2-3b-int8": {
        "name": "SeedVR2 3B (INT8, small)",
        "best_for": "SeedVR2 for cards with 8 GB",
        "description": (
            "The small version with 3 billion parameters (INT8, 3.5 GB). According to ByteDance slightly "
            "less detail than 7B, but it also fits into 8 GB of graphics memory. Not measured."
        ),
        "pros": [
            "Apache-2.0, free for commercial use",
            "One step: cleans up noise, grain and blur and enlarges at the same time",
            "Runs natively in ComfyUI, no extension needed",
        ],
        "cons": [
            "Does not repair scratches, tears or stains – \"Remove damage\" with FLUX 3 does that",
            "Invents fine detail (skin, fabric) at strong enlargement that was not in the original",
            "Less detail than 7B according to the manufacturer",
        ],
    },
    # Versions for AMD Radeon (since 0.5.12), see "Fassungen für AMD Radeon" in catalog.py.
    "qwen-image-2512-fp8": {
        "name": "Qwen-Image-2512 (FP8, for AMD Radeon)",
        "best_for": "Qwen-Image-2512 on AMD Radeon RX 9000 (FP8 in hardware)",
        "description": (
            "The same model as `qwen-image-2512-nvfp4`, in Comfy-Org's FP8 version (e4m3fn, 20.4 GB). Radeon RX 9000 "
            "(RDNA4) computes FP8 in hardware; on 16 GB ComfyUI streams part of it from system memory. Prompts and "
            "settings as with the NVFP4 version (50 steps, cfg 4).\n\n" + _AMD_NOTE
        ),
        "pros": ["FP8 runs in hardware on Radeon RX 9000", "Apache-2.0"],
        "cons": ["20.4 GB: on 16 GB ComfyUI streams parts of it", "Not tested on AMD yet"],
    },
    "flux3-klein-bf16": {
        "name": "FLUX 3 Image Klein (bf16, for AMD Radeon)",
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "FLUX 3 on AMD Radeon (bf16, fits into 16 GB)",
        "features": {"prompt_hint": FLUX3_PROMPT_HINT},
        "description": (
            "The same model as `flux3-klein-nvfp4`, in BFL's full bf16 version (11.1 GB). There is no FP8 version; "
            "bf16 runs on every Radeon without special kernels and fits into 16 GB. The text encoder Qwen3-VL-4B comes "
            "in FP8 from Comfy-Org's Krea-2 repo (the same weights as for FLUX 3, shared with Krea 2), the upsampler "
            "as in the INT8 version.\n\nGated repo: accept the license on Hugging Face and store a token.\n\n"
            + _AMD_NOTE
        ),
        "pros": ["Full precision, fits into 16 GB", "No special kernels needed"],
        "cons": ["Twice the size of INT8", "Gated repo: accept the license on Hugging Face and store a token",
                 "Not tested on AMD yet"],
    },
    "krea2-turbo-fp8": {
        "name": "Krea 2 Turbo (FP8, for AMD Radeon)",
        "warning": KREA2_LICENSE_WARNING,
        "best_for": "Krea 2 on AMD Radeon RX 9000 (FP8 in hardware)",
        "features": {"prompt_hint": KREA2_PROMPT_HINT},
        "description": (
            "The same model as `krea2-turbo-nvfp4`, in Comfy-Org's FP8 version (fp8_scaled, 13.1 GB), the text "
            "encoder in FP8 as well. Radeon RX 9000 (RDNA4) computes FP8 in hardware, and it fits into 16 GB. Prompt "
            "hints as for the NVFP4 version (state the framing).\n\nLicense: Krea 2 Community License — see "
            "warning.\n\n" + _AMD_NOTE
        ),
        "pros": ["FP8 runs in hardware on Radeon RX 9000", "Fits into 16 GB"],
        "cons": [_LICENSE_CON_KREA2, "Not tested on AMD yet"],
    },
    "moss-image-sft-bf16": {
        "name": "MOSS-Image SFT (bf16, for AMD Radeon)",
        "best_for": "MOSS-Image on AMD Radeon (bf16, fits into 16 GB)",
        "features": {"prompt_hint": MOSS_IMAGE_PROMPT_HINT},
        "description": (
            "The same model as `moss-image-sft-int8`, in Comfy-Org's bf16 version (10.2 GB): runs on every Radeon "
            "without special kernels and fits into 16 GB. Text and layout in the image under Apache-2.0; settings as "
            "with the INT8 version (50 steps, cfg 3).\n\n" + _AMD_NOTE
        ),
        "pros": ["Apache-2.0, can be sold without a revenue limit", "Full precision, fits into 16 GB"],
        "cons": ["Almost twice the size of INT8", "Not tested on AMD yet"],
    },
    "seedvr2-7b-fp8": {
        "name": "SeedVR2 7B (FP8, for AMD Radeon)",
        "best_for": "Sharpening and enlarging on AMD Radeon RX 9000 (FP8 in hardware)",
        "description": (
            "The same model as `seedvr2-7b-nvfp4`, in Comfy-Org's FP8 version (e4m3fn, 8.2 GB). Radeon RX 9000 "
            "(RDNA4) computes FP8 in hardware.\n\n" + _AMD_NOTE
        ),
        "pros": ["FP8 runs in hardware on Radeon RX 9000", "Apache-2.0"],
        "cons": ["Not tested on AMD yet"],
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
    # KREA2_SIZES (die beiden übrigen stehen schon bei FLUX 3)
    "1408 × 1408 — 2 MP, Objekte mit Detail": "1408 × 1408 — 2 MP, detailed objects",
    "1920 × 1088 — 2 MP 16:9, Panorama": "1920 × 1088 — 2 MP 16:9, panorama",
    # LTX25_SIZES
    "1920 × 1088 — 1080p, beste Qualität (rund 2,7-mal so lang)":
        "1920 × 1088 — 1080p, best quality (about 2.7 times as long)",
    "1088 × 1920 — 1080p hochkant, beste Qualität": "1088 × 1920 — 1080p portrait, best quality",
    "1280 × 704 — 16:9, 720p, schneller": "1280 × 704 — 16:9, 720p, faster",
    "704 × 1280 — 9:16, hochkant, schneller": "704 × 1280 — 9:16, portrait, faster",
    "1024 × 576 — 16:9, am schnellsten": "1024 × 576 — 16:9, fastest",
    "1024 × 1024 — quadratisch": "1024 × 1024 — square",
    # HIDREAM_O1_SIZES
    "2048 × 2048 — 4 MP, trainiert": "2048 × 2048 — 4 MP, trained",
    "1728 × 2304 — 4 MP hochkant, Figuren": "1728 × 2304 — 4 MP portrait, figures",
    "2304 × 1728 — 4 MP quer": "2304 × 1728 — 4 MP landscape",
    "1664 × 2496 — 4 MP 2:3, Figuren": "1664 × 2496 — 4 MP 2:3, figures",
    "2496 × 1664 — 4 MP 3:2, Fahrzeuge": "2496 × 1664 — 4 MP 3:2, vehicles",
    "2560 × 1440 — 4 MP 16:9, Panorama": "2560 × 1440 — 4 MP 16:9, panorama",
}
