from PIL import Image, ImageDraw

from bridge import imaging
from bridge.imaging import Rect


def test_working_size_keeps_aspect_near_one_megapixel():
    for w, h in [(1024, 1024), (4000, 3000), (300, 200), (1920, 1080), (832, 1216)]:
        gw, gh = imaging.working_size(w, h)
        assert gw % 16 == 0 and gh % 16 == 0
        assert 0.85e6 < gw * gh < 1.15e6
        assert abs(gw / gh - w / h) / (w / h) < 0.03


def test_working_size_clamps_extreme_formats():
    gw, gh = imaging.working_size(10000, 500)
    assert gw == imaging.MAX_SIDE
    assert gh >= imaging.MIN_SIDE
    gw, gh = imaging.working_size(100, 8000)
    assert gh == imaging.MAX_SIDE and gw >= imaging.MIN_SIDE


def test_context_region_adds_margin_and_stays_on_canvas():
    r = imaging.context_region(Rect(400, 250, 300, 200), 1200, 800, margin_frac=0.35)
    assert r == Rect(295, 145, 510, 410)
    edge = imaging.context_region(Rect(0, 0, 100, 100), 1200, 800)
    assert edge.x == 0 and edge.y == 0 and edge.w == 100 + 35 and edge.h == 100 + 35


def test_context_region_minimum_margin_for_small_selections():
    r = imaging.context_region(Rect(500, 500, 20, 20), 2000, 2000, margin_frac=0.35, min_margin=32)
    assert r == Rect(468, 468, 84, 84)


def test_mask_from_alpha_finds_transparent_border():
    img = Image.new("RGBA", (100, 80), (255, 0, 0, 255))
    ImageDraw.Draw(img).rectangle([80, 0, 99, 79], fill=(0, 0, 0, 0))
    mask = imaging.mask_from_alpha(img)
    assert mask is not None
    assert imaging.mask_bbox(mask) == Rect(80, 0, 20, 80)
    assert imaging.mask_from_alpha(Image.new("RGB", (10, 10))) is None
    assert imaging.mask_from_alpha(Image.new("RGBA", (10, 10), (1, 2, 3, 255))) is None


def test_flatten_for_model_fills_transparency_with_mean_colour():
    img = Image.new("RGBA", (10, 10), (0, 0, 0, 0))
    ImageDraw.Draw(img).rectangle([0, 0, 4, 9], fill=(200, 100, 50, 255))
    flat = imaging.flatten_for_model(img)
    assert flat.mode == "RGB"
    assert flat.getpixel((1, 1)) == (200, 100, 50)
    assert flat.getpixel((8, 8)) == (200, 100, 50)


def test_prepare_model_mask_grows_and_softens():
    mask = Image.new("L", (100, 100), 0)
    ImageDraw.Draw(mask).rectangle([40, 40, 59, 59], fill=255)
    grown = imaging.prepare_model_mask(mask, (100, 100), grow=5, blur=0)
    assert imaging.mask_bbox(grown, level=128) == Rect(35, 35, 30, 30)
    soft = imaging.prepare_model_mask(mask, (200, 200), grow=0, blur=4)
    assert soft.size == (200, 200)
    values = {soft.getpixel((x, 100)) for x in range(60, 100)}
    assert any(0 < v < 255 for v in values)


def test_fit_exact_and_bake_alpha():
    img = Image.new("RGB", (64, 32), (10, 20, 30))
    out = imaging.fit_exact(img, 100, 50)
    assert out.size == (100, 50)
    mask = Image.new("L", (100, 50), 0)
    ImageDraw.Draw(mask).rectangle([0, 0, 49, 49], fill=255)
    baked = imaging.bake_alpha(out, mask)
    assert baked.mode == "RGBA"
    assert baked.getpixel((10, 10))[3] == 255
    assert baked.getpixel((90, 10))[3] == 0
