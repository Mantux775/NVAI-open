"""MCP-Bruecke: macht NVAI-open in Claude Code als Werkzeug verfuegbar.

Bewusst ein duenner Client des REST-Servers -- keine eigene GPU-Logik. Damit
verhalten sich Frontend und Claude Code identisch und teilen dieselbe Queue.

Registrieren:
    claude mcp add nvai -- <repo>/server/.venv/Scripts/python.exe -m nvai.mcp_server
"""
from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

import httpx
# mcp>=2.0: FastMCP heisst jetzt MCPServer (gleiche Decorator-API).
from mcp.server.mcpserver import Context, MCPServer

from . import config

# Gleicher Port wie der Server -- bei der installierten Fassung aus der Registry (config).
API = os.getenv("NVAI_API_URL") or f"http://127.0.0.1:{config.API_PORT}"
POLL_INTERVAL = 1.0

server = MCPServer(
    "nvai",
    version="0.2.0",
    instructions=(
        "Local asset generation on the user's own GPU (NVIDIA; AMD Radeon experimental). "
        "All generate_* tools "
        "block until done and return absolute file paths that can be used directly in "
        "Unity or Blender. Call health() first: it shows the backend, the active models "
        "and the queue. On an AMD Radeon the -nvfp4 ids below are the wrong choice: use the "
        "versions list_models marks as recommended (FP8 or bf16 on a Radeon RX 9000, INT8 "
        "on other Radeons). FLUX 3 and LTX-2.5 need the license accepted on Hugging Face and "
        "a stored token; if download_model reports 'No access ... gated', send the user to "
        "the illustrated guide in the error message instead of retrying.\n\n"
        "IMAGE MODELS -- the four recommended ones (times measured on an RTX 5060 Ti 16 GB):\n"
        "1. qwen-image-2512-nvfp4 (Qwen-Image-2512, 50 steps, cfg 4, Apache-2.0, ~100 s "
        "at 1024x1024): for final assets, text in the image (letter-perfect) and structural "
        "details. Prompt in full English sentences: medium and style, then the subject with "
        "material, color and condition, construction stated explicitly ('rope handles pass "
        "through drilled holes'), then lighting and background. Text in quotation marks. "
        "The negative prompt works; empty = Qwen's recommended one.\n"
        "2. flux3-klein-nvfp4 (FLUX 3 Image Klein, 16 steps, ~30 s for a new prompt, "
        "13-16 s for a known one): editing and combining with up to 10 reference images "
        "(reference_asset_ids), keeping characters consistent across several images, "
        "placement by bounding box. An upsampler first expands the prompt into a full image "
        "description (returned as 'caption') -- a short, complete description is enough, "
        "but name the STYLE FIRST (otherwise it becomes a photo) and specify everything "
        "that has to be right (clothing, fastenings) explicitly: whatever is left open, the "
        "upsampler invents. The negative prompt has no effect. LICENSE: FLUX Kommunity "
        "License -- images may be used commercially only below US$5M annual revenue, and "
        "every image must be reviewed before publishing; point this out for final assets.\n"
        "3. krea2-turbo-nvfp4 (Krea 2 Turbo, 8 steps, ~20 s at 1 MP, 37 s at 2 MP): the most "
        "photographic of the three, natural hands and faces, letter-perfect text; no reference "
        "images. State the framing explicitly ('medium shot from the waist up, his whole head "
        "inside the frame'): without it the head of a man mending a net was cut off in three of "
        "three images, with it in none of two. The negative prompt has no effect. LICENSE: Krea 2 "
        "Community License -- commercial use only below US$1M annual revenue, every image must be "
        "reviewed by hand (or a content filter used), Krea can terminate with 30 days' notice; "
        "point this out for final assets.\n"
        "4. moss-image-sft-int8 (MOSS-Image by OpenMOSS, 50 steps, cfg 3, Apache-2.0, ~51 s at 1 MP, "
        "28 s with steps=25): text and layout in the image (posters, signs, graphics), free to sell "
        "without a revenue limit. Text came out letter-perfect in every test. Describe what the "
        "finished image looks like (medium and subject, setting and composition, light and colors), "
        "text in quotation marks with position and typeface. Short prompts are first expanded by "
        "MOSS's own text encoder (returned as 'caption', upsample_prompt=False switches it off); a "
        "JSON with 'summary' and 'items' as the prompt sets the layout. The negative prompt works. "
        "Text to image only: no reference images, no mask. Not available on the Mac.\n"
        "list_models(kind='image', detailed=True) returns 'features' for each model: which "
        "parameters have an effect, recommended sizes (sizes) and a prompt hint.\n\n"
        "SHORT PROMPTS: expand_prompt(prompt, width, height) turns a few words into a full "
        "image description for ANY image model (FLUX 3's upsampler, Apache-2.0, ~15 s). "
        "Measured: 'a medieval blacksmith' with Qwen-Image-2512 gave a warrior portrait; "
        "with the expanded text a whole forge with hearth, anvil, tongs and sparks. Read "
        "the result and remove invented details before generating (it gave the smith a "
        "helmet). Not needed for flux3-klein-* and moss-image-sft-int8: they expand internally.\n\n"
        "VIDEO -- the recommended model is LTX-2.5 (ltx25-distilled-nvfp4 on RTX 50, "
        "ltx25-distilled-int8 on older cards): picture and sound in one pass, 5 s at 1280x704 "
        "in ~93 s, at 1920x1088 in ~251 s on an RTX 5060 Ti. Prompt as one present-tense "
        "paragraph: shot, setting and "
        "light, the action with verbs, camera movement, then the sound; spoken lines in "
        "quotation marks; name loud sound sources explicitly (sounds described as soft came out "
        "very quiet). generate_video takes, for LTX-2.5 only: a start image, end_image_asset_id "
        "or loop=True (seamless loop; keep the camera still), quality='dfr' (more detail, "
        "slower; temporal_upscale for 48 fps), auto_duration, audio_asset_id (the picture "
        "follows a given sound, e.g. "
        "music from generate_audio) and motion_speed (slow motion with the Slow Motion LoRA; "
        "measured at 1920x1088 and 0.2: a wave's spray fell over 5 s instead of 1.5 s with sharp "
        "droplets, without the LoRA it froze into a milky veil). "
        "Several shots in one clip: write the cuts out in prose (expand_prompt "
        "target='video_multishot'). list_models(kind='lora') marks LoRAs recommended for "
        "LTX-2.5 in features.recommended_for. The Cinemagraph LoRA (trigger CINEMAGRAPH_MOTION) "
        "only works with a start image and loop=True: measured 6 % of the picture moving with a "
        "still face, 82-84 % without loop. A person from a photo in a video: first "
        "generate_image with flux3-klein-*, the photo (cropped to head and shoulders) in "
        "reference_asset_ids, batch_size=4, in the video size, prompt 'Cinematic film still. The "
        "person from the first image, with exactly the same face, eyes, nose, mouth and hair "
        "color: <role>. Medium shot from the waist up, the face clearly visible.'; pick the most "
        "similar face at full resolution, then generate_video with image_asset_id. Keep the "
        "person facing the camera; turned away, the face is redrawn and looks less alike.\n"
        "Prefer the higher quality and say so: final videos at 1920x1088 (5 s in ~251 s, about "
        "2.7 times 720p), start images in that size too, and quality='dfr' when the model's "
        "features.dfr is true (detail stays sharp over the whole clip, about 3 times the time; not "
        "with an end image or loop). If the face has to stay recognizable "
        "after a zoom out or a big move, give an end image made with flux3-klein-* and the same "
        "references (the last frame then matches it; a wider end image comes from outpaint, "
        "FLUX ignored 'wider shot' when editing). Measured prompt traps: 'shouts' gives "
        "grimaces ('says firmly in a rough, deep voice' is calmer); a gesture that may 'rise out "
        "of the frame' makes the camera follow it; for a fixed frame write 'Static camera, a "
        "locked-off medium shot; the framing stays exactly as in the first frame.'; 'calm, "
        "proud expression' became a grin ('stern, determined, does not smile'). Thin props "
        "(rifles, flag poles) that cross people in the start image morph into each other.\n\n"
        "OLD PHOTOS: restore_image(image_path or image_asset_id) removes damage (repair), colorizes "
        "(colorize) and sharpens with SeedVR2 (sharpen). repair_mode='auto' (default) lets FLUX 3's upsampler "
        "look at the photo first and asks whether it has water stains or crack networks: yes -> 'thorough' "
        "(redraws the whole picture; cracks, scratches, water stains and fading go, faces can change slightly "
        "per seed, so keep batch_size=2 and compare), no -> 'gentle' (only replaces detected damage, keeps the "
        "photo's sharpness, faces and detail exactly). It matched the expected mode on 20 of 21 test photos. "
        "Set the mode yourself only when you know better: overall aging (water stains, crack networks, grain, "
        "fading) -> thorough, where gentle left the damage and a user found the result 'only colorized, worse "
        "than before'; separate damage on an otherwise good photo (dust, scratches, tears, light leaks, "
        "writing) -> gentle, where thorough came out softer on real glass plates. The result's "
        "meta.repair.auto says what auto chose. "
        "Colorizing takes only the color from FLUX 3 and keeps the photo's brightness and detail; known "
        "colors in `notes` cut the measured color error by 40 %.\n\n"
        "Always: choose the size to match the silhouette (standing figure portrait, vehicle "
        "landscape), use batch_size=4 when a choice is wanted, look at results at full "
        "resolution and check that every part is sensibly attached before passing them on."
    ),
)


async def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(base_url=API, timeout=60.0)


async def _wait_for_job(job_id: str, ctx: Context | None = None, timeout: float = 1800.0) -> dict[str, Any]:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    last_progress = -1.0
    async with await _client() as c:
        while loop.time() < deadline:
            job = (await c.get(f"/api/jobs/{job_id}")).json()
            if ctx and job["progress"] != last_progress:
                last_progress = job["progress"]
                await ctx.report_progress(job["progress"], 1.0)
            if job["status"] in ("done", "error", "cancelled"):
                return job
            await asyncio.sleep(POLL_INTERVAL)
    raise TimeoutError(f"Job {job_id} not finished after {timeout}s")


def _asset_paths(assets: list[dict[str, Any]]) -> list[str]:
    from . import config

    return [str(config.ASSET_DIR / a["filename"]) for a in assets]


async def _generate(path: str, payload: dict[str, Any], ctx: Context) -> dict[str, Any]:
    """Job absetzen, auf das Ende warten, Ergebnispfade zurueckgeben.
    Gemeinsamer Kern von generate_image / _audio / _video."""
    async with await _client() as c:
        r = await c.post(path, json=payload)
        if r.status_code >= 400:
            return {"ok": False, "error": r.text[:500]}
        job = r.json()

    result = await _wait_for_job(job["id"], ctx)
    if result["status"] != "done":
        return {"ok": False, "error": result.get("error") or result["status"]}

    async with await _client() as c:
        assets = (await c.get(f"/api/jobs/{job['id']}/assets")).json()

    first = assets[0] if assets else {}
    meta = first.get("meta", {})
    out = {
        "ok": True,
        "job_id": job["id"],
        "files": _asset_paths(assets),
        "asset_ids": [a["id"] for a in assets],
        "urls": [f"{API}{a['url']}" for a in assets],
        "kind": first.get("kind"),
        "seed": meta.get("seed"),
        "model_id": first.get("model_id"),
    }
    # FLUX 3: die Bildbeschreibung, die der Upsampler aus dem Prompt gemacht hat. Stimmt
    # am Bild etwas nicht, zeigt sie, ob es schon in der Beschreibung fehlte.
    if meta.get("caption"):
        out["caption"] = meta["caption"]
    return out


@server.tool()
async def health() -> dict[str, Any]:
    """NVAI-open status: is the GPU backend running, which model is active, how full is the queue."""
    async with await _client() as c:
        return (await c.get("/api/health")).json()


@server.tool()
async def list_models(kind: str | None = None, detailed: bool = False) -> list[dict[str, Any]]:
    """All known models with installation status, size, VRAM requirement and license.

    Args:
        kind: 'image', 'audio', 'video', '3d', 'lora' or 'upscale' (SeedVR2 for restore_image);
            None = all. LoRAs carry their family (which models they fit) and 'trigger' words for the prompt.
        detailed: Also return the description, pros and cons.
    """
    async with await _client() as c:
        models = (await c.get("/api/models", params={"kind": kind} if kind else None)).json()
    out = []
    for m in models:
        row = {
            "id": m["id"], "name": m["name"], "kind": m["kind"],
            "installed": m["installed"], "runnable": m["runnable"],
            "favorite": m.get("favorite", False),
            "size_gb": m["size_gb"], "vram_gb": m["vram_gb"],
            "license": m["license"], "commercial_ok": m["commercial_ok"],
            "best_for": m["best_for"],
        }
        if m.get("warning"):
            row["warning"] = m["warning"]
        # Empfehlung fuer die erkannte Grafikkarte (RTX 50: NVFP4, aeltere: INT8) und der
        # Hinweis, wenn ein Format auf dieser Karte nicht in Hardware rechnet.
        if m.get("recommended"):
            row["recommended"] = True
        if m.get("gpu_note"):
            row["gpu_note"] = m["gpu_note"]
        if m.get("lora_bases"):
            row["lora_bases"] = m["lora_bases"]
        if m["kind"] == "lora":
            row |= {"family": m["family"], "trigger": m.get("trigger", ""),
                    "source_url": m.get("source_url", "")}
        if detailed:
            row |= {"description": m["description"], "pros": m["pros"], "cons": m["cons"],
                    "features": m.get("features", {})}
        out.append(row)
    return out


@server.tool()
async def delete_model(model_id: str) -> dict[str, Any]:
    """Deletes a model's files from disk and frees the space.

    Files that another installed model still needs (such as a shared text
    encoder) are kept.

    Args:
        model_id: ID from list_models().
    """
    async with await _client() as c:
        r = await c.delete(f"/api/models/{model_id}")
        if r.status_code >= 400:
            return {"ok": False, "error": r.json().get("detail", r.text)}
        return {"ok": True, **r.json()}


@server.tool()
async def download_model(model_id: str, ctx: Context) -> dict[str, Any]:
    """Downloads a model from the catalog to the local disk. Several GB, so this can take a while.

    Args:
        model_id: ID from list_models(), e.g. 'sdxl-base'.
    """
    async with await _client() as c:
        job = (await c.post("/api/models/download", json={"model_id": model_id})).json()
    result = await _wait_for_job(job["id"], ctx)
    if result["status"] == "error":
        return {"ok": False, "error": result["error"]}
    return {"ok": True, "model_id": model_id}


@server.tool()
async def set_active_model(model_id: str) -> dict[str, Any]:
    """Sets the default model of its category.

    The category follows from the model: an image model becomes the default
    for generate_image, an audio model for generate_audio, and so on.
    """
    async with await _client() as c:
        r = await c.post("/api/models/active", json={"model_id": model_id})
        if r.status_code >= 400:
            return {"ok": False, "error": r.json().get("detail", r.text)}
        return {"ok": True, **r.json()}


@server.tool()
async def generate_image(
    prompt: str,
    ctx: Context,
    negative_prompt: str = "",
    width: int = 1024,
    height: int = 1024,
    model_id: str | None = None,
    steps: int | None = None,
    cfg: float | None = None,
    sampler: str | None = None,
    scheduler: str | None = None,
    seed: int | None = None,
    batch_size: int = 1,
    hires: bool = False,
    hires_scale: float = 1.25,
    hires_denoise: float = 0.45,
    slg: bool = False,
    slg_scale: float = 3.0,
    image_asset_id: str | None = None,
    denoise: float = 1.0,
    mask_asset_id: str | None = None,
    outpaint: list[int] | None = None,
    reference_asset_ids: list[str] | None = None,
    upsample_prompt: bool | None = None,
    controlnet_model_id: str | None = None,
    controlnet_image_asset_id: str | None = None,
    controlnet_strength: float = 0.7,
    controlnet_end: float = 0.8,
    controlnet_preprocess: str = "none",
    loras: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Generates an image locally on the GPU and returns file paths and asset IDs.

    Blocks until the generation is finished. Which parameters have an effect with the
    chosen model is listed in list_models(kind="image", detailed=True) under 'features'.

    QUALITY -- what helps most, in this order:
    1. The right model (see the server instructions): qwen-image-2512-nvfp4 for
       final assets and text, flux3-klein-nvfp4 for editing with reference images.
    2. Size to match the silhouette: figures 832x1216, vehicles landscape 1216x832,
       objects 1024x1024. More detail: Qwen native (e.g. 1328x1328, 1056x1584), FLUX 3
       up to 2048x2048 -- costs correspondingly more time.
    3. Prompt in full sentences, construction stated explicitly ("rope handles pass
       through drilled holes in the side boards"), text in quotation marks.
    4. batch_size=4 and take the best -- errors are a failure rate.

    Args:
        prompt: What should be created, in full English sentences. For FLUX 3 a short,
            complete request is enough -- the upsampler writes the long version.
            For Qwen, be detailed yourself: medium, subject, material, lighting, background.
        negative_prompt: Only has an effect with CFG > 1 (Qwen 50 steps, FLUX 3 Base), NOT
            with flux3-klein-nvfp4 and Lightning. Empty = model default (for Qwen the one
            from its model card). Style bans flatten the look.
        width, height: Resolution, a multiple of 16 (FLUX 3) or 8.
        model_id: Force a model; otherwise the active one.
        steps, cfg, sampler, scheduler: None = model default. Only change them if you
            know why -- karras and exponential make deformations worse.
        seed: For reproducible results.
        batch_size: Variants in one run, one model load instead of four.
        hires: Second pass on an upscaled latent (Qwen and older models).
            With FLUX 3, choose a larger size directly instead.
        hires_scale, hires_denoise: 1.25 and 0.45 are the safe values.
        slg, slg_scale: SD 3.5 only -- ignore for other models.
        image_asset_id: Existing image as a starting point (img2img, with denoise). With
            FLUX 3 it becomes the first reference instead.
        denoise: Only with image_asset_id: 0.3 gentle, 0.6 noticeable, 1.0 discards everything.
        mask_asset_id: Only with image_asset_id: mask (white = generate anew, black =
            keep) as an uploaded asset. With denoise=1.0 this is inpainting. With
            flux3-klein-nvfp4 the server marks the area grey, lets FLUX 3 fill it from the
            prompt and puts back only the masked area, aligned (measured: a replaced sign kept
            its position and perspective, Qwen-Image-2512 painted it flat and frontal). With
            Qwen use the full model -- Lightning mostly just continues the surroundings.
        outpaint: Only with image_asset_id: extend the image beyond its edges,
            [left, top, right, bottom] in pixels (0-1024 each). width/height follow from
            image plus border; the server sets everything else. The prompt describes the
            whole extended picture. Use flux3-klein-nvfp4 (or another model with
            reference images): measured seamless, and the original stays pixel for pixel.
            Qwen-Image-2512 works via a mask but often paints the border as a separate
            scene with a hard edge at the old image border.
        reference_asset_ids: FLUX 3: up to 10 image assets. Refer to them in the
            prompt as "the first image", "the second image": "Put the soldier from the first
            image into the trench from the second image" or "Replace the rope handles with
            iron handles; keep everything else unchanged". Qwen-Image 2.1 also takes up
            to 10; there they are called <image1>, <image2> (non-commercial license).
        upsample_prompt: FLUX 3 only. None/True = upsampler on (BFL's recommendation).
            False only if the prompt already is a full image description of 100-350 words.
            Bounding boxes: append a table to the end of the prompt, e.g. [{"id": "crate_1",
            "bbox": [top, left, bottom, right] on 0-1000, "desc": "..."}]. Do NOT cite the
            ids in the text as <crate_1> -- the upsampler does that, and the boxes stay
            fixed. A text that cites all ids counts as a finished description and goes to
            the model without the upsampler.
        controlnet_*: SD 3.5 only -- ignore for other models.
        loras: LoRAs as [{"model_id": "...", "strength": 0.8}]. Only installed LoRAs whose
            family fits the model: list_models(kind="lora") lists them, and each image or
            video model names the LoRA families it takes in 'lora_bases'. Put the LoRA's
            'trigger' words into the prompt. 0.6-1.0 is the usual strength.

    Returns:
        files, asset_ids, seed, model_id; for FLUX 3 also 'caption' -- the description
        the image was actually generated from.
    """
    payload = {
        "prompt": prompt, "negative_prompt": negative_prompt,
        "width": width, "height": height, "model_id": model_id,
        "steps": steps, "cfg": cfg, "sampler": sampler, "scheduler": scheduler,
        "seed": seed, "batch_size": batch_size,
        "hires": hires, "hires_scale": hires_scale, "hires_denoise": hires_denoise,
        "slg": slg, "slg_scale": slg_scale,
        "image_asset_id": image_asset_id, "denoise": denoise,
        "mask_asset_id": mask_asset_id,
        "outpaint": outpaint,
        "reference_asset_ids": reference_asset_ids or [],
        "upsample_prompt": upsample_prompt,
        "controlnet_model_id": controlnet_model_id,
        "controlnet_image_asset_id": controlnet_image_asset_id,
        "controlnet_strength": controlnet_strength,
        "controlnet_end": controlnet_end,
        "controlnet_preprocess": controlnet_preprocess,
        "loras": loras or [],
    }
    return await _generate("/api/generate/image", payload, ctx)


@server.tool()
async def restore_image(
    ctx: Context,
    image_asset_id: str | None = None,
    image_path: str | None = None,
    repair: bool = True,
    repair_mode: str = "auto",
    colorize: bool = False,
    sharpen: bool = False,
    scale: float = 2.0,
    notes: str = "",
    batch_size: int = 2,
    megapixels: float | None = None,
    model_id: str | None = None,
    seed: int | None = None,
) -> dict[str, Any]:
    """Restores an old photo: removes damage, colorizes, sharpens -- each step can be switched on or off.

    Blocks until done. Steps run in this order; times measured on an RTX 5060 Ti with FLUX 3 Klein NVFP4:
    1. repair: FLUX 3 removes scratches, dust, cracks, stains, creases, tears and emulsion damage.
       repair_mode='thorough' takes the whole picture from FLUX: cracks, fine scratches, water stains and
       fading go (film grain partly stays), but faces can change with the seed -- one of two variants of a
       1911 portrait got a wider face, so compare the variants. 'gentle' keeps the photo's detail and faces
       at full resolution and only puts in the damage NVAI-open detects, plus FLUX's contrast and fading
       correction. It depends on the kind of damage: overall aging (water stains, crack networks, grain,
       fading) -> thorough; separate damage on an otherwise good photo (dust, scratches, tears, light
       leaks) -> gentle. 'auto' (default) decides that by asking FLUX 3's upsampler, which sees the photo,
       whether it shows water stains or crack networks (about 2.5 s; 20 of 21 test photos as expected, the
       one miss was a sharp glass plate with dust that got thorough); meta.repair.auto holds the choice.
       Measured on test photos with a known original (similarity at a quarter of the size): heavily aged
       0.601 untouched, 0.648 gentle, 0.689 thorough; lightly aged 0.921, 0.932 gentle, 0.911 thorough
       (it drew faces in a group photo differently). On real glass
       plates and a 1945 photo with a light leak gentle kept the sharpness, thorough came out softer.
       Works at 2 MP (capped at the photo's size); a 2-variant job took 70 s at 1 MP and 150 s at 2 MP.
       Small faces in group photos need the 2 MP.
    2. colorize: FLUX 3 colorizes, but only the color is taken over -- brightness, detail and resolution
       stay those of the photo (FLUX alone smoothed the skin and changed a smile). Put known colors into
       `notes` in English ("her dress is dark red with white dots, the car is pale turquoise"): measured
       on a photo with known colors, the color error fell by 40 %. About 40 s per variant.
    3. sharpen: SeedVR2 (Apache-2.0, list_models(kind='upscale')) sharpens, removes coarse grain (in a test
       even at scale 1, which also redrew the face a little; fine noise in calm areas stayed) and enlarges to
       photo size x `scale` (at most 16 MP): 1200x864 -> 3840x2770 in 18.5 s. It invents fine detail at
       strong enlargement.

    Args:
        image_asset_id: The photo as an asset (from list_assets or a previous result).
        image_path: Or a local image file (PNG, JPEG, WebP); it is uploaded first.
        repair: Remove damage.
        repair_mode: 'auto' (default), 'thorough' or 'gentle', see above.
        colorize: Colorize a black-and-white or sepia photo.
        sharpen: Sharpen and enlarge with SeedVR2 at the end.
        scale: Only with sharpen: enlargement relative to the photo, 1-4.
        notes: Optional English hints: colors, what to keep or remove ("remove the handwritten numbers").
        batch_size: Variants (1-4). With repair, look at the faces at full resolution and pick.
        megapixels: Working size of FLUX for the repair (0.5-4); None = 2.
        model_id: Editing model; None = FLUX 3 Klein.
        seed: For reproducible results.

    Returns:
        files, asset_ids, seed. LICENSE: FLUX 3 output (repair, colorize) falls under the FLUX Kommunity
        License -- review before publishing; SeedVR2 is Apache-2.0.
    """
    if not image_asset_id and not image_path:
        return {"ok": False, "error": "image_asset_id or image_path is required"}
    if image_path and not image_asset_id:
        path = Path(image_path)
        if not path.is_file():
            return {"ok": False, "error": f"file not found: {image_path}"}
        async with await _client() as c:
            r = await c.post("/api/upload", files={"file": (path.name, path.read_bytes())}, timeout=120.0)
            if r.status_code >= 400:
                return {"ok": False, "error": r.text[:500]}
            image_asset_id = r.json()["id"]
    payload = {
        "image_asset_id": image_asset_id, "repair": repair, "repair_mode": repair_mode,
        "colorize": colorize, "sharpen": sharpen, "scale": scale, "notes": notes,
        "batch_size": batch_size, "megapixels": megapixels, "model_id": model_id, "seed": seed,
    }
    return await _generate("/api/image/restore", payload, ctx)


@server.tool()
async def expand_prompt(
    prompt: str,
    width: int = 1024,
    height: int = 1024,
    reference_asset_ids: list[str] | None = None,
    target: str = "image",
) -> dict[str, Any]:
    """Expands a short prompt into a full prompt -- for images, video, sound or 3D.

    Uses the prompt upsampler that comes with FLUX 3 Image Klein (Qwen3.5-9B,
    Apache-2.0) -- it needs that model downloaded. About 15 s on an RTX 5060 Ti, longer
    if a generation is running (it waits in the GPU queue). Only text, no image.

    Use it when the user gives just a few words ("a medieval blacksmith") and the
    image model is Qwen, SDXL, Chroma or another one without its own upsampler. Then
    pass 'expanded' as the prompt to generate_image. Whatever the short prompt left
    open, the upsampler invents (in a test it put a helmet on a blacksmith): read
    'expanded' and remove or correct such details first. Not needed for flux3-klein-*
    models, which expand internally (upsample_prompt).

    Args:
        prompt: The short prompt, preferably in English.
        width, height: The planned image size -- the upsampler composes for it.
        reference_asset_ids: Optional images the upsampler looks at (FLUX 3 editing,
            or the start image with target 'video_start').
        target: 'image' (default), 'video' (Wan, LTX-Video: motion and camera),
            'video_sound' (LTX-2.5: also describes the sound), 'video_multishot' (LTX-2.5:
            2-4 shots in one clip, every cut written out, sound across the cuts), 'video_start' (image to
            video: motion only, reads the start image), 'sfx' (Stable Audio: sound
            tags), 'music' (ACE-Step genre tags), 'music_sa3' (Stable Audio 3: one
            sentence plus BPM, wordless choir at most; the length is added on generating)
            or '3d' (an image prompt for one object without floor or shadow, then
            image_to_3d). Measured 3-12 s each.

    Returns:
        prompt (as given), expanded (the full description), seconds.
    """
    async with await _client() as c:
        r = await c.post("/api/prompt/expand", timeout=960.0, json={
            "prompt": prompt, "width": width, "height": height,
            "reference_asset_ids": reference_asset_ids or [], "target": target,
        })
        if r.status_code != 200:
            return {"ok": False, "error": r.json().get("detail", r.text)}
        return {"ok": True, **r.json()}


@server.tool()
async def generate_audio(
    prompt: str,
    ctx: Context,
    seconds: float = 10.0,
    lyrics: str = "",
    negative_prompt: str = "",
    model_id: str | None = None,
    seed: int | None = None,
    bpm: int | None = None,
    time_signature: str | None = None,
    key_scale: str | None = None,
) -> dict[str, Any]:
    """Generates audio locally on the GPU and returns the file paths.

    Depending on the active model: Stable Audio Open for sound effects and ambience
    (describe the sound, e.g. "footsteps on gravel, close mic"), ACE-Step for
    music with vocals or choir (genre tags, e.g. "epic orchestral, choir, drums"),
    stable-audio-3-medium for instrumental music up to a few minutes (no vocals; one
    sentence: genre with main instruments, layers and percussion creating a mood, then
    "BPM: 100. Length: 60 seconds").

    Args:
        prompt: Sound description (SFX), genre tags (ACE-Step) or one descriptive sentence
            (Stable Audio 3).
        seconds: Length in seconds. Stable Audio Open can do up to 47 s.
        lyrics: ACE-Step only: song lyrics. Empty = instrumental.
        negative_prompt: What to avoid.
        model_id: Force a model; otherwise the active audio model.
        seed: For reproducible results.
        bpm: ACE-Step 1.5 only: tempo, 40-240. Default 120.
        time_signature: ACE-Step 1.5 only: "2" (2/4), "3" (3/4), "4" (4/4) or "6" (6/8). Default "4".
        key_scale: ACE-Step 1.5 only: key such as "Bb major" or "A minor". Default "C major".
    """
    payload = {
        "prompt": prompt, "negative_prompt": negative_prompt, "lyrics": lyrics,
        "seconds": seconds, "model_id": model_id, "seed": seed,
        "bpm": bpm, "time_signature": time_signature, "key_scale": key_scale,
    }
    return await _generate("/api/generate/audio", payload, ctx)


@server.tool()
async def generate_video(
    prompt: str,
    ctx: Context,
    width: int = 832,
    height: int = 480,
    frames: int = 49,
    fps: int = 16,
    negative_prompt: str = "",
    model_id: str | None = None,
    seed: int | None = None,
    image_asset_id: str | None = None,
    loras: list[dict[str, Any]] | None = None,
    end_image_asset_id: str | None = None,
    loop: bool = False,
    quality: str = "standard",
    temporal_upscale: bool = False,
    auto_duration: bool = False,
    audio_asset_id: str | None = None,
    motion_speed: float = 1.0,
    crf: float | None = None,
    extend_asset_id: str | None = None,
) -> dict[str, Any]:
    """Generates a short video locally on the GPU and returns the file paths.

    Takes one to several minutes, depending on the model. The frame count is rounded to the
    grid the model requires (Wan 4n+1, LTX 8n+1).

    RECOMMENDED: LTX-2.5 (ltx25-distilled-nvfp4, or ltx25-distilled-int8 on RTX 20/30/40):
    picture and sound in one pass, MP4. Use fps=24, sizes from its features.sizes: 1920x1088
    (1080p) for final videos, about 2.7 times as long as 1280x704 (720p, for drafts) -- say so
    to the user. Frames 97 = 4 s, 121 = 5 s, up to 481 = 20 s.

    Image-to-video: with `image_asset_id`, an existing image is brought to life instead
    of generating one from nothing. The models wan22-i2v-a14b, wan21-i2v-480p-14b and
    kandinsky5-lite-i2v require it. The asset ID comes from
    list_assets(kind="image") or from the return value of generate_image.

    Args:
        prompt: What should be visible -- describe it in detail, including motion.
            For image-to-video, describe only the motion; don't retell the image.
            LTX-2.5: one present-tense paragraph -- shot, setting and light, the action with
            verbs, camera movement, last the sound; dialogue in quotation marks. Several
            shots: write each cut out in prose ("A hard cut transitions to a close-up of
            ..."), 2-4 shots; expand_prompt(target='video_multishot') writes that form.
        width, height: Resolution. 832x480 is the cheapest Wan default. For
            image-to-video, match the start image's aspect ratio where possible.
        frames: Number of frames. 49 at 16 fps is just over 3 seconds.
        fps: Frame rate of the output file.
        negative_prompt: Empty = sensible default. No effect with HunyuanVideo 1.5.
        model_id: Force a model; otherwise the active video model.
        seed: For reproducible results.
        image_asset_id: Asset ID of the start image for image-to-video.
        loras: LoRAs as [{"model_id": "...", "strength": 0.8}]. Only installed LoRAs whose
            family fits the model: list_models(kind="lora") lists them, and each image or
            video model names the LoRA families it takes in 'lora_bases'. Put the LoRA's
            'trigger' words into the prompt. 0.6-1.0 is the usual strength.
            Wan 2.2 A14B LoRAs often come as a high-noise and a low-noise file: load
            both, each is applied to its own expert automatically.
            LoRAs recommended for LTX-2.5 carry features.recommended_for=['ltx25'] and a
            recommended features.strength (download them with download_model).
        end_image_asset_id: LTX-2.5: last frame. With image_asset_id the clip moves from
            the start image to the end image (transition); without it, it ends on it.
        loop: LTX-2.5: the start image is also the end image -- a seamless loop. Keep the
            camera still and describe a repeating motion (flames, water, breathing); with a
            camera move the last frames fell apart in the test.
        quality: LTX-2.5: 'standard' or 'dfr' (Diffusion Fidelity Rendering: detail
            keyframes plus a detail IC-LoRA). Measured at 1080p: faces and fabric stay sharp over
            the whole clip (face 2.5 to 3 times the edge sharpness of 'standard' after 2 s), at
            about three times the time (5 s: 786 instead of 241 s). Prefer it for final videos when
            features.dfr is true, and say so. Not with an end image or a loop.
        temporal_upscale: LTX-2.5 with quality='dfr': double frame rate at the same
            duration (24 -> 48 fps).
        auto_duration: LTX-2.5: the model picks the length from the described action
            (1-20 s); `frames` is ignored. Write pauses ("a beat of silence") into the
            prompt if the clip should hold.
        audio_asset_id: LTX-2.5: a sound the picture follows (e.g. music from
            generate_audio). The clip gets its length (at most 20 s), the original sound
            ends up in the MP4.
        motion_speed: LTX-2.5: slow motion, 1 = real time, 0.5 = 2x, 0.2 = 5x, 0.1 = 10x
            slower at the same playback fps. Reliable together with the Slow Motion
            Control LoRA and a start image.
        crf: LTX-2.5: H.264 quality of the MP4 (CRF, lower = better and larger). Empty =
            12; ComfyUI's own default of 18 gave only 6 to 13 Mbit/s at 1080p.
        extend_asset_id: LTX-2.5: continue an existing video (asset ID of a video). Its last frame
            becomes the start image, size and frame rate come from it, and the new part is appended
            with its sound; the prompt describes what happens next, frames/seconds its length. The
            result lists the extended video first, then the new part on its own. Not together with
            image_asset_id, loop or audio_asset_id.
    """
    payload = {
        "prompt": prompt, "negative_prompt": negative_prompt,
        "width": width, "height": height, "frames": frames, "fps": fps,
        "model_id": model_id, "seed": seed, "image_asset_id": image_asset_id,
        "loras": loras or [], "end_image_asset_id": end_image_asset_id, "loop": loop,
        "quality": quality, "temporal_upscale": temporal_upscale,
        "auto_duration": auto_duration, "audio_asset_id": audio_asset_id,
        "motion_speed": motion_speed, "crf": crf, "extend_asset_id": extend_asset_id,
    }
    return await _generate("/api/generate/video", payload, ctx)


# Zusaetze, die ein Bild fuer die 3D-Rekonstruktion brauchbar machen. Ohne sie
# landen Boden, Schatten und Umgebung als Geometrie im Mesh.
#
# Wichtig: Ein Sockel, der zum Objekt GEHOERT (Statue auf ihrer Steinplatte),
# soll erhalten bleiben. Ausgeschlossen wird nur, worauf das Objekt zusaetzlich
# gestellt wird -- Boden, Tisch, Schlagschatten. Deshalb steht hier weder
# "no base" noch "pedestal" im Negativ.
#
# In ganzen Saetzen und positiv formuliert: Qwen und FLUX 3 lesen den Prompt mit einem
# Sprachmodell, und bei cfg-1-Modellen (FLUX 3 destilliert) wirkt der Negativprompt nicht
# -- "schwebt vor leerem Grund" traegt dort, "no floor" nicht.
MESH_PROMPT_SUFFIX = (
    "Show the complete object, including any base or plinth that belongs to it, as a "
    "single subject, centered and fully visible. It floats in empty space against a "
    "plain, flat light grey background, lit by even, diffuse, shadowless studio light. "
    "Product shot."
)
MESH_NEGATIVE = (
    "cast shadow, drop shadow, floor, ground plane, table surface, room, landscape, "
    "environment, background objects, multiple objects, cropped, text, watermark"
)


@server.tool()
async def image_to_3d(
    image_asset_id: str,
    ctx: Context,
    faces: int = 100_000,
    seed: int | None = None,
    texture_size: int = 2048,
    background_mode: str = "birefnet",
    clean_specks: bool = True,
    steps: int = 50,
    project_front: bool = False,
) -> dict[str, Any]:
    """Creates a 3D mesh (GLB) from an existing image asset and returns its path.

    Uses the active 3D model: TRELLIS.2 delivers geometry WITH PBR textures,
    TripoSG geometry only. Both work purely from the image -- there is no
    text prompt for this stage. Whatever is in the image ends up in the mesh.

    The source image determines the quality: a single, free-standing object
    without floor or shadow. For text-to-mesh in one step, use text_to_3d
    instead.

    Args:
        image_asset_id: Asset ID of an image from list_assets() or of an upload.
        faces: Target triangle count after reduction. For game assets 10,000-100,000.
        seed: For reproducible results.
        texture_size: TRELLIS.2 only: texture resolution 1024/2048/4096.
        background_mode: 'birefnet' (cleanest edges, recommended), 'flood' (fast,
            only with a calm background) or 'alpha' (the image brings its own alpha).
        clean_specks: Remove loose mesh fragments -- the typical floating strands
            and pillars.
        steps: TripoSG only: sampling steps.
        project_front: Put the source image onto the visible front of the mesh (planar
            projection) so lettering and stickers stay readable; TRELLIS.2 otherwise paints
            text as gibberish. The rest keeps its texture (TRELLIS.2) or gets colors from the
            blurred image (TripoSG). Best for objects with a clear front (signs, crates).
    """
    payload = {
        "image_asset_id": image_asset_id, "steps": steps, "faces": faces,
        "seed": seed, "texture_size": texture_size,
        "background_mode": background_mode, "clean_specks": clean_specks,
        "remove_background": background_mode != "alpha", "project_front": project_front,
    }
    return await _generate("/api/generate/3d", payload, ctx)


@server.tool()
async def text_to_3d(
    prompt: str,
    ctx: Context,
    faces: int = 100_000,
    seed: int | None = None,
    texture_size: int = 2048,
    image_model_id: str | None = None,
    negative_prompt: str = "",
    auto_prompt: bool = True,
    project_front: bool = False,
) -> dict[str, Any]:
    """Text to 3D mesh in one pass: first an image, then the mesh from it.

    The 3D models themselves don't understand text -- the prompt affects the image,
    and the image determines the mesh. That's why this tool automatically appends
    what the reconstruction needs: a single free-standing object, no floor, no
    shadow, a calm background. That is exactly where most attempts fail otherwise
    -- an image with floor contact yields a mesh with a ground plate grown onto
    it.

    Takes as long as both steps together, typically two to four minutes.

    Args:
        prompt: What kind of object to create, e.g. "a weathered stone gargoyle".
        faces: Target triangle count of the finished mesh.
        seed: Affects the image; same seed and prompt = same result.
        texture_size: Texture resolution with TRELLIS.2.
        image_model_id: Force an image model; otherwise the active one.
        negative_prompt: Additional exclusions (no effect with cfg-1 models).
        auto_prompt: Append the 3D-friendly additions. Only turn this off if you
            have already written the prompt fully for this purpose.
        project_front: Put the generated image onto the visible front of the mesh, so
            lettering stays readable (see image_to_3d).
    """
    full_prompt = f"{prompt.rstrip(' .,')}. {MESH_PROMPT_SUFFIX}" if auto_prompt else prompt
    full_negative = (
        f"{negative_prompt}, {MESH_NEGATIVE}".strip(", ") if auto_prompt else negative_prompt
    )

    image = await _generate("/api/generate/image", {
        "prompt": full_prompt, "negative_prompt": full_negative,
        "width": 1024, "height": 1024, "model_id": image_model_id,
        "steps": None, "seed": seed, "batch_size": 1,
    }, ctx)
    if not image.get("ok"):
        return {"ok": False, "stage": "image", "error": image.get("error")}

    async with await _client() as c:
        assets = (await c.get(f"/api/jobs/{image['job_id']}/assets")).json()
    if not assets:
        return {"ok": False, "stage": "image", "error": "no image asset was generated"}

    mesh = await _generate("/api/generate/3d", {
        "image_asset_id": assets[0]["id"], "faces": faces, "seed": seed,
        "texture_size": texture_size, "background_mode": "birefnet",
        "clean_specks": True, "remove_background": True, "steps": 50,
        "project_front": project_front,
    }, ctx)
    if not mesh.get("ok"):
        return {"ok": False, "stage": "mesh", "error": mesh.get("error"),
                "image": image.get("files")}

    return {
        "ok": True,
        "mesh": mesh.get("files"),
        "image": image.get("files"),
        "image_asset_id": assets[0]["id"],
        "prompt_used": full_prompt,
        "model_id": mesh.get("model_id"),
    }


@server.tool()
async def list_assets(kind: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    """Most recently generated assets with prompt, path and model.

    Args:
        kind: 'image', 'mesh' or 'upload'; None = everything.
        limit: Number of entries.
    """
    from . import config

    params: dict[str, Any] = {"limit": limit}
    if kind:
        params["kind"] = kind
    async with await _client() as c:
        assets = (await c.get("/api/assets", params=params)).json()
    return [
        {
            "id": a["id"], "kind": a["kind"], "prompt": a["prompt"], "model_id": a["model_id"],
            "path": str(config.ASSET_DIR / a["filename"]), "created_at": a["created_at"],
        }
        for a in assets
    ]


@server.tool()
async def delete_asset(asset_id: str) -> dict[str, Any]:
    """Deletes a single asset, including its file, from the history.

    Args:
        asset_id: ID from list_assets().
    """
    async with await _client() as c:
        r = await c.delete(f"/api/assets/{asset_id}")
        if r.status_code >= 400:
            return {"ok": False, "error": r.text[:300]}
        return r.json()


@server.tool()
async def clear_history(kind: str | None = None, confirm: bool = False) -> dict[str, Any]:
    """Clears the generation history and deletes the associated files.

    Irreversible. Models are not affected, only generated assets.

    Args:
        kind: 'image', 'audio' or 'video'; None = everything.
        confirm: Must be explicitly true, otherwise nothing happens.
    """
    if not confirm:
        return {"ok": False, "error": "confirm=true required -- the history would be gone for good."}
    async with await _client() as c:
        r = await c.delete("/api/history", params={"kind": kind} if kind else None)
        if r.status_code >= 400:
            return {"ok": False, "error": r.json().get("detail", r.text)}
        return r.json()


@server.tool()
async def copy_asset(asset_id: str, destination: str) -> dict[str, Any]:
    """Copies an asset to any path, e.g. into Assets/Generated/ of a Unity project.

    Args:
        asset_id: ID from list_assets().
        destination: Target folder or full target file path.
    """
    import shutil

    from . import config

    async with await _client() as c:
        r = await c.get(f"/api/assets/{asset_id}")
        if r.status_code >= 400:
            return {"ok": False, "error": "Asset not found"}
        asset = r.json()

    src = config.ASSET_DIR / asset["filename"]
    dest = Path(destination)
    if dest.is_dir() or not dest.suffix:
        dest.mkdir(parents=True, exist_ok=True)
        dest = dest / asset["filename"]
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return {"ok": True, "path": str(dest)}


def main() -> None:
    server.run()


if __name__ == "__main__":
    main()
