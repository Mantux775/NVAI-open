import pytest

from bridge import planning
from bridge.imaging import Rect
from bridge.planning import PlanError, capable, choose_model, layer_name, plan, technique_for

QWEN = {"id": "qwen-image-2512-nvfp4", "name": "Qwen voll", "workflow": "qwen_image", "runnable": True,
        "features": {"img2img": True, "mask": True, "hires": True, "negative_prompt": True,
                     "default_negative": "低分辨率", "references": 0}}
LIGHT = {"id": "qwen-image-2512-lightning", "name": "Qwen Lightning", "workflow": "qwen_image_lightning",
         "runnable": True, "features": {"img2img": True, "mask": True, "hires": True, "references": 0}}
FLUX3 = {"id": "flux3-klein-nvfp4", "name": "FLUX 3", "workflow": "flux3_klein", "runnable": True,
         "features": {"img2img": False, "mask": False, "hires": False, "references": 10}}
MODELS = [QWEN, FLUX3, LIGHT]


def test_capable_uses_features_and_falls_back_for_old_servers():
    qwen_old = {"features": {"img2img": True}}  # Server ohne „mask“-Schlüssel
    assert capable(qwen_old, "img2img", masks_supported=False)
    assert not capable(qwen_old, "mask", masks_supported=False)
    assert capable(qwen_old, "mask", masks_supported=True)
    assert not capable(FLUX3, "img2img", masks_supported=True)
    assert not capable(FLUX3, "mask", masks_supported=True)
    assert capable(FLUX3, "refine", masks_supported=False)
    assert capable({}, "img2img", masks_supported=False)
    assert not capable({"features": {"img2img": False, "references": 0}}, "refine", masks_supported=True)


def test_choose_model_keeps_capable_active_and_falls_back_otherwise():
    assert choose_model("fill", None, "qwen-image-2512-nvfp4", MODELS, True) == (QWEN, None)
    model, warning = choose_model("fill", None, "flux3-klein-nvfp4", MODELS, True)
    assert model is QWEN and warning.code == "active_model_incapable"
    model, warning = choose_model("generate", None, None, MODELS, True)
    assert model is QWEN and warning.code == "no_active_model"
    model, warning = choose_model("refine", None, "flux3-klein-nvfp4", MODELS, True)
    assert model is FLUX3 and warning is None
    with pytest.raises(PlanError) as err:
        choose_model("fill", "flux3-klein-nvfp4", "qwen-image-2512-nvfp4", MODELS, True)
    assert err.value.code == "model_incapable"
    with pytest.raises(PlanError) as err:
        choose_model("fill", None, None, [FLUX3], True)
    assert err.value.code == "no_capable_model"


def test_technique_per_mode():
    assert technique_for("generate", QWEN, True, True) == "txt2img"
    assert technique_for("fill", QWEN, True, True) == "inpaint"
    assert technique_for("refine", QWEN, True, True) == "inpaint"
    assert technique_for("refine", QWEN, False, True) == "img2img"
    assert technique_for("refine", {"features": {"img2img": True}}, True, False) == "img2img"
    assert technique_for("refine", FLUX3, True, True) == "reference"


def test_plan_fill_without_prompt_keeps_model_default_negative():
    p = plan("fill", "", {"variants": 2}, QWEN, (632, 548), True, False, True)
    assert p.technique == "inpaint" and p.send_image and p.send_mask
    assert p.payload["prompt"] == planning.DEFAULT_FILL_PROMPT
    assert p.payload["negative_prompt"].startswith("低分辨率 ")
    assert p.payload["steps"] == 28 and p.payload["denoise"] == 1.0 and p.payload["batch_size"] == 2
    assert (p.mask_grow, p.mask_blur) == (12, 10.0)


def test_plan_outpaint_uses_wide_blend_band():
    p = plan("fill", "", {}, QWEN, (1152, 832), True, True, True)
    assert (p.mask_grow, p.mask_blur) == (planning.OUTPAINT_GROW, planning.OUTPAINT_BLUR)


def test_plan_reference_edit_and_rules():
    p = plan("refine", "make it blue", {"strength": 0.7, "hires": True}, FLUX3, (432, 332), True, False, True)
    assert p.technique == "reference" and p.send_image and not p.send_mask
    assert "denoise" not in p.payload and "hires" not in p.payload and "steps" not in p.payload
    with pytest.raises(PlanError):
        plan("refine", "", {}, FLUX3, (432, 332), True, False, True)
    with pytest.raises(PlanError):
        plan("generate", "  ", {}, QWEN, (400, 300), False, False, True)
    w = plan("fill", "a horse", {}, LIGHT, (400, 300), True, False, True).warnings
    assert [x.code for x in w] == ["weak_prompt_fill"]
    native = plan("generate", "x", {"native": True}, QWEN, (1000, 1000), False, False, True)
    assert native.working == (1328, 1328)


COREML = {"id": "coreml-sd21-base", "name": "SD 2.1 (Core ML)", "workflow": "coreml_sd", "runnable": True,
          "features": {"img2img": True, "mask": False, "hires": False, "references": 0, "fixed_size": 512}}


def test_fixed_size_models_are_asked_for_their_square():
    # NV-AI für Mac streckt sonst selbst auf die angefragte Größe – verzerrt.
    p = plan("generate", "a horse", {"native": True}, COREML, (1216, 832), False, False, True)
    assert p.working == (512, 512) and (p.payload["width"], p.payload["height"]) == (512, 512)
    assert [w.code for w in p.warnings] == ["fixed_size"] and "cropped" in p.warnings[0].message
    p = plan("refine", "a horse", {}, COREML, (500, 1500), False, False, True)
    assert p.technique == "img2img" and p.working == (512, 512) and "squeezed" in p.warnings[0].message
    assert plan("generate", "a horse", {}, COREML, (600, 560), False, False, True).warnings == []
    assert not capable(COREML, "mask", masks_supported=True)  # Füllen bleibt gesperrt


@pytest.mark.parametrize("value, size", [(512, 512), (768.0, 768), (512.5, None), (True, None), (0, None), ("512", None)])
def test_fixed_size_reading(value, size):
    assert planning.fixed_size({"features": {"fixed_size": value}}) == size


def test_regions():
    assert planning.region_for("generate", None, 1200, 800) == Rect(0, 0, 1200, 800)
    assert planning.region_for("refine", Rect(700, 120, 400, 300), 1200, 800) == Rect(684, 104, 432, 332)
    assert planning.region_for("fill", Rect(680, 430, 340, 280), 1216, 832) == Rect(561, 311, 578, 518)
    assert planning.outpaint_region(Rect(1216, 0, 320, 832), 1536, 832) == Rect(384, 0, 1152, 832)


def test_layer_name_is_short_and_numbered():
    name = layer_name("generate", "a " * 60, 1, 2)
    assert name.startswith("NV-AI Generate: ") and name.endswith("(2)") and len(name) < 80
    assert layer_name("fill", "", 0, 1) == "NV-AI Fill"


def test_extend_steps_anchor_on_the_opposite_side():
    assert planning.extend_steps(None) == []
    assert planning.extend_steps([0, 0, 0, 0]) == []
    steps = planning.extend_steps([256, 0, 0, 128])
    assert [(s["width"], s["height"], s["anchor"]) for s in steps] == [(256, 0, "right"), (0, 128, "top")]
    assert all(s["relative"] and s["extensionColor"] == "transparent" for s in steps)


def test_extend_steps_equal_edges_in_one_centered_step():
    steps = planning.extend_steps([200, 64, 200, 0])
    assert [(s["width"], s["height"], s["anchor"]) for s in steps] == [(400, 0, "center"), (0, 64, "bottom")]


def test_extend_steps_clamps():
    steps = planning.extend_steps([-5, 0, 99999, 0])
    assert [(s["width"], s["anchor"]) for s in steps] == [(planning.EXTEND_MAX, "left")]


def test_outpaint_edges_scales_box_and_edges():
    from PIL import Image
    img = Image.new("RGBA", (400, 200), (0, 0, 0, 0))
    img.paste((10, 20, 30, 255), (0, 0, 300, 200))  # rechts 100 px durchsichtig
    box, size, edges = planning.outpaint_edges(img, (800, 400))
    assert box == (0, 0, 300, 200)
    assert size == (600, 400)
    assert edges == [0, 0, 200, 0]
    assert planning.outpaint_edges(Image.new("RGBA", (10, 10), (1, 2, 3, 255)), (10, 10)) is None
    assert planning.outpaint_edges(Image.new("RGB", (10, 10)), (10, 10)) is None


def test_extend_prefers_seamless_reference_model():
    qwen = {**QWEN, "features": {**QWEN["features"], "outpaint": "mask"}}
    flux = {**FLUX3, "features": {**FLUX3["features"], "outpaint": "reference"}}
    model, warning = choose_model("fill", None, qwen["id"], [qwen, flux], True, extend=True)
    assert model["id"] == flux["id"] and warning is None
    # Eigene Wahl bleibt, wenn das Modell erweitern kann.
    model, _ = choose_model("fill", qwen["id"], None, [qwen, flux], True, extend=True)
    assert model["id"] == qwen["id"]
    # Ohne extend bleibt Füllen beim Maskenmodell.
    model, _ = choose_model("fill", None, flux["id"], [qwen, flux], True)
    assert model["id"] == qwen["id"]


def test_plan_outpaint_leaves_mask_and_denoise_to_the_server():
    flux = {**FLUX3, "features": {**FLUX3["features"], "outpaint": "reference"}}
    p = plan("fill", "", {"variants": 2}, flux, (1216, 832), True, True, True, outpaint=True)
    assert p.technique == "outpaint"
    assert not p.send_mask and p.send_image
    assert "denoise" not in p.payload
