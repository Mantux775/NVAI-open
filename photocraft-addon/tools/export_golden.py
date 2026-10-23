"""Golden-Testdaten für den Swift-Port (PhotoCraftKit) erzeugen.

    python tools/export_golden.py          # schreibt golden/*.json
    python tools/export_golden.py --check  # vergleicht nur (Exit 1 bei Abweichung)
    python tools/export_golden.py --refresh-contract  # zuerst den NV-AI-Vertrag neu übernehmen

- golden/imaging.json   – Geometrie exakt, Bildoperationen mit Toleranzen (Core Image rechnet
                          Weichzeichner und Skalierung nicht bitgleich zu Pillow)
- golden/planning.json  – Modellwahl, Technik, Request – exakt, Warnungen als Codes
- golden/sequences.json – Steuerbefehle samt Antworten für Erfassen und Einfügen (Replay)
- contract/nvai-openapi.json geht unverändert als Golden/nvai-openapi.json zu den Swift-Tests

Rechtecke in den Eingaben sind halboffen: [x0, y0, x1, y1) – x1/y1 gehören nicht dazu.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from PIL import Image, ImageDraw  # noqa: E402

from bridge import config, i18n, imaging, planning  # noqa: E402
from bridge.imaging import Rect  # noqa: E402

GOLDEN = ROOT / "golden"


# ------------------------------------------------------------------ Imaging

def draw_mask(size: list[int], rects: list[list[int]], base: int = 0) -> Image.Image:
    m = Image.new("L", tuple(size), base)
    d = ImageDraw.Draw(m)
    for x0, y0, x1, y1, value in rects:
        d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=value)
    return m


def draw_rgba(size: list[int], base: list[int], rects: list[list[int]]) -> Image.Image:
    img = Image.new("RGBA", tuple(size), tuple(base))
    d = ImageDraw.Draw(img)
    for x0, y0, x1, y1, r, g, b, a in rects:
        d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(r, g, b, a))
    return img


def bbox(r: Rect | None) -> list[int] | None:
    return r.as_list() if r else None


def imaging_cases() -> dict[str, Any]:
    sizes = [(1024, 1024), (4000, 3000), (300, 200), (1920, 1080), (832, 1216), (432, 332), (1216, 832),
             (611, 832), (1152, 832), (100, 8000), (10000, 500), (20, 20), (5000, 5000), (1, 1), (777, 333)]
    working = [{"in": {"w": w, "h": h, "target": t}, "out": list(imaging.working_size(w, h, t))}
               for w, h in sizes for t in (imaging.TARGET_PIXELS, 1328 * 1328, 1440 * 1440)]
    context = []
    for sel, wh, frac in [([400, 250, 300, 200], (1200, 800), 0.35), ([0, 0, 100, 100], (1200, 800), 0.35),
                          ([500, 500, 20, 20], (2000, 2000), 0.35), ([680, 430, 340, 280], (1216, 832), 0.35),
                          ([1216, 0, 320, 832], (1536, 832), 1.0), ([389, 239, 322, 242], (1200, 800), 0.5),
                          ([10, 10, 1180, 780], (1200, 800), 0.35), ([1100, 700, 100, 100], (1200, 800), 0.1)]:
        context.append({"in": {"sel": sel, "width": wh[0], "height": wh[1], "margin_frac": frac, "min_margin": 32},
                        "out": imaging.context_region(Rect.from_list(sel), wh[0], wh[1], frac).as_list()})
    grow = [{"in": {"rect": r, "margin": m, "width": 1200, "height": 800},
             "out": imaging.grow_rect(Rect.from_list(r), m, 1200, 800).as_list()}
            for r, m in [([700, 120, 400, 300], 16), ([0, 0, 10, 10], 16), ([1190, 790, 10, 10], 50)]]

    mask_bbox = []
    for size, rects, level in [([100, 80], [[80, 0, 100, 80, 255]], 8), ([50, 50], [], 8),
                               ([64, 64], [[10, 20, 30, 40, 5]], 8), ([64, 64], [[10, 20, 30, 40, 9]], 8),
                               ([64, 64], [[1, 2, 3, 4, 200], [40, 50, 41, 51, 255]], 128)]:
        mask_bbox.append({"in": {"size": size, "rects": rects, "level": level},
                          "out": bbox(imaging.mask_bbox(draw_mask(size, rects), level))})

    alpha = []
    for size, base, rects, threshold in [([100, 80], [255, 0, 0, 255], [[80, 0, 100, 80, 0, 0, 0, 0]], 250),
                                         ([10, 10], [1, 2, 3, 255], [], 250),
                                         ([40, 30], [9, 9, 9, 255], [[0, 0, 40, 5, 9, 9, 9, 249]], 250),
                                         ([40, 30], [9, 9, 9, 255], [[0, 0, 40, 5, 9, 9, 9, 250]], 250)]:
        m = imaging.mask_from_alpha(draw_rgba(size, base, rects), threshold)
        alpha.append({"in": {"size": size, "base": base, "rects": rects, "threshold": threshold},
                      "out": bbox(imaging.mask_bbox(m)) if m is not None else None})

    prepare = []
    for size, rects, out_size, g, b in [([100, 100], [[40, 40, 60, 60, 255]], [100, 100], 5, 0.0),
                                        ([100, 100], [[40, 40, 60, 60, 255]], [200, 200], 0, 4.0),
                                        ([320, 240], [[100, 60, 220, 180, 255]], [1184, 880], 12, 10.0),
                                        ([611, 832], [[291, 0, 611, 832, 255]], [880, 1200], 24, 20.0)]:
        m = imaging.prepare_model_mask(draw_mask(size, rects), tuple(out_size), g, b)
        w, h = out_size
        points = [(w // 2, h // 2), (0, 0), (w - 1, h - 1), (w // 4, h // 2), (3 * w // 4, h // 2), (w // 2, h // 4)]
        prepare.append({"in": {"size": size, "rects": rects, "out_size": out_size, "grow": g, "blur": b},
                        "out": {"bbox_128": bbox(imaging.mask_bbox(m, 128)), "bbox_8": bbox(imaging.mask_bbox(m, 8)),
                                "samples": [[x, y, m.getpixel((x, y))] for x, y in points],
                                "has_soft_edge": any(0 < v < 255 for v in m.tobytes())},
                        "tolerance": {"bbox": max(2, round(b)), "value": 40}})

    flatten = []
    for size, base, rects in [([10, 10], [0, 0, 0, 0], [[0, 0, 5, 10, 200, 100, 50, 255]]),
                              ([8, 8], [10, 20, 30, 255], []),
                              ([6, 4], [0, 0, 0, 0], []),
                              ([20, 10], [0, 0, 0, 0], [[0, 0, 10, 10, 255, 0, 0, 255], [10, 0, 15, 10, 0, 0, 255, 255]])]:
        img = imaging.flatten_for_model(draw_rgba(size, base, rects))
        w, h = size
        flatten.append({"in": {"size": size, "base": base, "rects": rects},
                        "out": {"samples": [[x, y, list(img.getpixel((x, y)))] for x, y in [(0, 0), (w - 1, h - 1), (w // 2, 0)]]},
                        "tolerance": 2})

    bake = []
    for size, rects, img_size in [([100, 50], [[0, 0, 50, 50, 255]], [100, 50]), ([50, 25], [[0, 0, 25, 25, 255]], [100, 50])]:
        out = imaging.bake_alpha(Image.new("RGB", tuple(img_size), (10, 20, 30)), draw_mask(size, rects))
        w, h = img_size
        bake.append({"in": {"mask_size": size, "rects": rects, "image_size": img_size, "rgb": [10, 20, 30]},
                     "out": {"samples": [[x, y, out.getpixel((x, y))[3]] for x, y in [(10, 10), (w - 10, 10), (w // 2 - 2, h // 2)]]},
                     "tolerance": 40})

    return {"version": 1, "generated_by": "tools/export_golden.py",
            "constants": {"TARGET_PIXELS": imaging.TARGET_PIXELS, "MIN_SIDE": imaging.MIN_SIDE,
                          "MAX_SIDE": imaging.MAX_SIDE, "MULTIPLE": imaging.MULTIPLE},
            "working_size": working, "context_region": context, "grow_rect": grow, "mask_bbox": mask_bbox,
            "mask_from_alpha": alpha, "prepare_model_mask": prepare, "flatten_for_model": flatten,
            "bake_alpha": bake}


# ----------------------------------------------------------------- Planning

MODELS = {
    "qwen": {"id": "qwen-image-2512-nvfp4", "name": "Qwen-Image-2512 (NVFP4)", "workflow": "qwen_image", "runnable": True,
             "features": {"steps": 50, "cfg": 4.0, "negative_prompt": True, "default_negative": "低分辨率，低画质",
                          "upsampler": False, "references": 0, "bbox": False, "img2img": True, "mask": True, "hires": True}},
    "lightning": {"id": "qwen-image-2512-lightning", "name": "Qwen-Image-2512 Lightning", "workflow": "qwen_image_lightning",
                  "runnable": True, "features": {"steps": 8, "cfg": 1.0, "negative_prompt": False, "default_negative": "",
                                                 "references": 0, "img2img": True, "mask": True, "hires": True}},
    "flux3": {"id": "flux3-klein-nvfp4", "name": "FLUX 3 Image Klein", "workflow": "flux3_klein", "runnable": True,
              "features": {"steps": 16, "cfg": 1.0, "negative_prompt": False, "upsampler": True, "references": 10,
                           "img2img": False, "mask": False, "hires": False}},
    # NV-AI für Mac: FLUX.2 Klein über MLX und ein Core-ML-Modell mit festem Format.
    "flux2": {"id": "flux2-klein-4b", "name": "FLUX.2 Klein 4B", "workflow": "flux2_klein", "runnable": True,
              "features": {"steps": 4, "cfg": 1.0, "negative_prompt": False, "references": 3, "img2img": True,
                           "mask": True, "hires": False}},
    "coreml": {"id": "coreml-sd21-base", "name": "Stable Diffusion 2.1 (Core ML)", "workflow": "coreml_sd",
               "runnable": True, "features": {"img2img": True, "mask": False, "hires": False, "references": 0,
                                              "fixed_size": 512}},
    "old_server": {"id": "sdxl-base", "name": "SDXL (ohne features)", "workflow": "sdxl", "runnable": True},
    "not_installed": {"id": "chroma1-hd-fp8", "name": "Chroma", "workflow": "chroma", "runnable": False,
                      "features": {"img2img": True}},
}


def plan_out(fn) -> dict[str, Any]:
    try:
        return fn()
    except planning.PlanError as exc:
        return {"error": exc.code}


def planning_cases() -> dict[str, Any]:
    capable = [{"model": name, "need": need, "masks_supported": masks,
                "out": planning.capable(MODELS[name], need, masks)}
               for name in MODELS for need in ("img2img", "refine", "mask") for masks in (False, True)]

    choose = []
    lists = {"all": ["qwen", "flux3", "lightning", "not_installed"], "flux_only": ["flux3"],
             "light_first": ["lightning", "qwen", "flux3"], "old": ["old_server"]}
    for mode in planning.BASE_MODES:
        for list_name, names in lists.items():
            for wanted in (None, "qwen-image-2512-nvfp4", "flux3-klein-nvfp4", "gone-model"):
                for active in (None, "qwen-image-2512-nvfp4", "flux3-klein-nvfp4", "chroma1-hd-fp8"):
                    for masks in (False, True):
                        models = [MODELS[n] for n in names]

                        def run(models=models, mode=mode, wanted=wanted, active=active, masks=masks):
                            m, w = planning.choose_model(mode, wanted, active, models, masks)
                            return {"model": m["id"], "warning": w.code if w else None}

                        choose.append({"in": {"mode": mode, "wanted": wanted, "active": active, "models": names,
                                              "masks_supported": masks}, "out": plan_out(run)})

    technique = [{"in": {"mode": mode, "model": name, "has_mask": has, "masks_supported": masks},
                  "out": planning.technique_for(mode, MODELS[name], has, masks)}
                 for mode in planning.BASE_MODES for name in ("qwen", "flux3", "flux2", "coreml", "old_server")
                 for has in (False, True) for masks in (False, True)]

    regions = []
    for mode in planning.BASE_MODES:
        for sel, wh in [(None, (1200, 800)), ([700, 120, 400, 300], (1200, 800)), ([680, 430, 340, 280], (1216, 832)),
                        ([0, 0, 50, 50], (640, 480)), ([389, 239, 322, 242], (1200, 800))]:
            r = planning.region_for(mode, Rect.from_list(sel) if sel else None, wh[0], wh[1], 0.35)
            regions.append({"in": {"mode": mode, "selection": sel, "width": wh[0], "height": wh[1], "margin": 0.35},
                            "out": r.as_list()})
    outpaint = [{"in": {"transparent": t, "width": w, "height": h, "margin": 0.35},
                 "out": planning.outpaint_region(Rect.from_list(t), w, h, 0.35).as_list()}
                for t, w, h in [([1216, 0, 320, 832], 1536, 832), ([0, 0, 1536, 200], 1536, 1032), ([100, 100, 50, 50], 400, 400)]]

    plans = []

    def add_plan(mode, prompt, params, name, size, has_mask, alpha):
        def run():
            p = planning.plan(mode, prompt, params, MODELS[name], size, has_mask, alpha, True)
            return {"model_id": p.model_id, "technique": p.technique, "working": list(p.working),
                    "payload": p.payload, "send_image": p.send_image, "send_mask": p.send_mask,
                    "mask_grow": p.mask_grow, "mask_blur": p.mask_blur,
                    "warnings": [w.code for w in p.warnings]}

        plans.append({"in": {"mode": mode, "prompt": prompt, "params": params, "model": name,
                             "region_size": list(size), "has_mask": has_mask, "alpha_mask": alpha,
                             "masks_supported": True}, "out": plan_out(run)})

    prompts = ["", "A brown horse grazing on the meadow."]
    param_sets = [{}, {"variants": 3, "strength": 0.7}, {"native": True, "hires": True},
                  {"steps": 40, "cfg": 3.5, "seed": 7, "negative_prompt": "blurry"}, {"variants": 9}]
    for mode in planning.BASE_MODES:
        for name in ("qwen", "lightning", "flux3", "flux2", "coreml", "old_server"):
            for prompt in prompts:
                for params in param_sets:
                    for has_mask, alpha in ((False, False), (True, False), (True, True)):
                        if alpha and mode != "fill":
                            continue
                        add_plan(mode, prompt, params, name, (632, 548) if has_mask else (1216, 832), has_mask, alpha)
    # Festes Format: fast quadratisch ohne Warnung, sehr breit mit.
    for mode, size in (("generate", (600, 560)), ("refine", (560, 600)), ("generate", (1500, 500)), ("refine", (500, 1500))):
        add_plan(mode, "A brown horse grazing on the meadow.", {}, "coreml", size, False, False)

    # Ebenennamen sind sichtbar und deshalb übersetzt: beide Sprachen festhalten.
    names = []
    before = i18n.choice()
    for lang in ("en", "de"):
        i18n.set_choice(lang)
        names += [{"in": {"mode": m, "prompt": p, "k": k, "n": n, "lang": lang}, "out": planning.layer_name(m, p, k, n)}
                  for m, p, k, n in [("fill", "", 0, 1), ("generate", "a " * 60, 1, 2),
                                     ("refine", "  make   it  blue ", 0, 1), ("fill", "x" * 48, 2, 4),
                                     ("fill", "x" * 49, 0, 1)]]
    i18n.set_choice(before)

    return {"version": 1, "generated_by": "tools/export_golden.py", "models": MODELS,
            "constants": {"DEFAULT_FILL_PROMPT": planning.DEFAULT_FILL_PROMPT,
                          "DEFAULT_FILL_NEGATIVE": planning.DEFAULT_FILL_NEGATIVE,
                          "INTERACTIVE_STEPS": planning.INTERACTIVE_STEPS,
                          "WEAK_PROMPT_WORKFLOWS": sorted(planning.WEAK_PROMPT_WORKFLOWS),
                          "NATIVE_PIXELS": planning.NATIVE_PIXELS, "MASK_GROW": planning.MASK_GROW,
                          "MASK_BLUR": planning.MASK_BLUR, "OUTPAINT_GROW": planning.OUTPAINT_GROW,
                          "OUTPAINT_BLUR": planning.OUTPAINT_BLUR, "OUTPAINT_MARGIN": planning.OUTPAINT_MARGIN,
                          "REFINE_PAD": planning.REFINE_PAD},
            "capable": capable, "choose_model": choose, "technique_for": technique, "region_for": regions,
            "outpaint_region": outpaint, "plan": plans, "layer_name": names}


# ---------------------------------------------------------------- Sequenzen

def sequences() -> dict[str, Any]:
    out: dict[str, Any] = {}
    saved_dirs = config.EXCHANGE_DIR, config.JOBS_DIR
    with tempfile.TemporaryDirectory() as tmp:
        exchange = Path(tmp) / "exchange"
        config.EXCHANGE_DIR, config.JOBS_DIR = exchange, exchange / "jobs"
        config.JOBS_DIR.mkdir(parents=True)
        try:
            _run_scenarios(out, exchange)
        finally:
            config.EXCHANGE_DIR, config.JOBS_DIR = saved_dirs
    return {"version": 1, "generated_by": "tools/export_golden.py",
            "note": "Replay: Anfragen müssen in Reihenfolge und Inhalt gleich sein; Antworten werden "
                    "zurückgespielt. Pfade jobs/<task-id>/… liegen im Austauschordner.",
            "scenarios": out}


def _run_scenarios(out: dict[str, Any], exchange: Path) -> None:
    from fake_photocraft import FakePhotoCraft, write_png

    from bridge import tasks

    def scenario(name: str, mode: str, doc: dict[str, Any], others: list[str], steps) -> None:
        pc = FakePhotoCraft(exchange)
        for other in others:
            pc.add_document(other, 640, 480)
        pc.add_document(doc["name"], doc["width"], doc["height"], doc.get("selection"))
        setup = {"documents": [{"name": n, "width": 640, "height": 480} for n in others]
                 + [{"name": doc["name"], "width": doc["width"], "height": doc["height"],
                     "selection": doc.get("selection")}], "active": len(others),
                 "next_layer_id": 101 + len(others) + 1}
        mgr = tasks.TaskManager(pc, nv=None)  # type: ignore[arg-type]
        t = tasks.Task(id=f"T-{name}", mode=mode, prompt="a red barn", params={"mode": mode, "margin": 0.35})
        job_dir = config.JOBS_DIR / t.id
        job_dir.mkdir(parents=True, exist_ok=True)
        notes = steps(pc, mgr, t, job_dir)
        out[name] = {"setup": setup, "task": {"id": t.id, "mode": mode, "prompt": t.prompt, "margin": 0.35},
                     "notes": notes, "transcript": pc.transcript,
                     "final": {"region": t.region, "selection": t.selection, "has_mask": t.has_mask,
                               "placed_layer": t.placed_layer, "placed_variant": t.placed_variant}}

    def capture_only(pc, mgr, t, job_dir):
        mgr._capture(t, f"jobs/{t.id}", job_dir)
        return "Erfassen"

    def capture_and_place(pc, mgr, t, job_dir):
        mgr._capture(t, f"jobs/{t.id}", job_dir)
        region = Rect.from_list(t.region)
        for k in (1, 2):
            write_png(job_dir / f"result-{k}.png", region.w, region.h)
        t.variants = [tasks.Variant(index=0, file=f"jobs/{t.id}/result-1.png", thumb=""),
                      tasks.Variant(index=1, file=f"jobs/{t.id}/result-2.png", thumb="")]
        mgr.place(t, 0, replace=False)
        mgr.place(t, 1, replace=True)
        return "Erfassen, Variante 1 einfügen, Variante 2 tauschen (Auswahl unverändert)"

    def place_after_selection_change(pc, mgr, t, job_dir):
        capture_and_place(pc, mgr, t, job_dir)
        pc.docs[pc.active]["selection"] = [10, 10, 50, 50]  # Nutzer wählt etwas anderes aus
        mgr.place(t, 0, replace=True)
        return "wie oben, dann Auswahl geändert und Variante 1 zurückgetauscht (Maske der alten Ebene)"

    doc = {"name": "Bild.psd", "width": 1200, "height": 800, "selection": [389, 239, 322, 242]}
    scenario("capture_fill_selection", "fill", doc, [], capture_only)
    scenario("capture_generate_no_selection", "generate", {**doc, "selection": None}, [], capture_only)
    scenario("capture_refine_selection_third_tab", "refine", doc, ["Erstes", "Zweites"], capture_only)
    scenario("fill_place_and_swap", "fill", doc, [], capture_and_place)
    scenario("fill_swap_after_selection_change", "fill", doc, ["Erstes"], place_after_selection_change)


SWIFT_GOLDEN = ROOT / "PhotoCraftKit" / "Tests" / "PhotoCraftKitTests" / "Golden"
# API-Vertrag von NV-AI (Kopie von NV-AI/server/openapi.json, gepflegt von NV-AI).
CONTRACT = ROOT / "contract" / "nvai-openapi.json"


def refresh_contract() -> None:
    source = config.NVAI_ROOT / "server" / "openapi.json"
    CONTRACT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, CONTRACT)
    info = json.loads(CONTRACT.read_text(encoding="utf-8"))["info"]
    # Nur ASCII: die Windows-Konsole (cp1252) kennt keine Pfeile.
    print(f"{CONTRACT.relative_to(ROOT)}: aus {source} (NV-AI {info['version']}, API {info['x-api-version']})")


def main() -> int:
    check = "--check" in sys.argv
    i18n.set_choice("en")  # Golden-Daten auf Englisch, unabhängig von der Systemsprache
    if "--refresh-contract" in sys.argv and not check:
        refresh_contract()
    data = {"imaging.json": imaging_cases(), "planning.json": planning_cases(), "sequences.json": sequences()}
    outputs: dict[Path, str] = {}
    for folder in (GOLDEN, SWIFT_GOLDEN):  # Repo-Referenz und Kopie für die Swift-Tests
        for name, content in data.items():
            outputs[folder / name] = json.dumps(content, ensure_ascii=False, indent=1) + "\n"
    # Der Vertrag geht unverändert mit, damit die Swift-Tests ihn ohne NV-AI prüfen können.
    outputs[SWIFT_GOLDEN / CONTRACT.name] = CONTRACT.read_text(encoding="utf-8")
    differs = []
    for path, text in outputs.items():
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                differs.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"{path.relative_to(ROOT)}: {len(text) // 1024} KB")
    if check and differs:
        print("Golden-Daten veraltet:", ", ".join(differs))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
