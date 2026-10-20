# blender -b --factory-startup -P turntable.py -- <in.glb> <out_dir> <frames> <size>
# Renders a GLB on a turntable: the model turns once around its vertical axis.
import math
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_dir = argv[0], argv[1]
frames = int(argv[2]) if len(argv) > 2 else 48
size = int(argv[3]) if len(argv) > 3 else 480

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
center, extent = (lo + hi) / 2, max(hi - lo)

# Model centred on the turntable axis, scaled to 2 units; the pivot turns.
inner = bpy.data.objects.new("inner", None)
pivot = bpy.data.objects.new("pivot", None)
for o in (inner, pivot):
    bpy.context.scene.collection.objects.link(o)
for o in [o for o in bpy.context.scene.objects if o.parent is None and o not in (inner, pivot)]:
    o.parent = inner
inner.location = -center
inner.parent = pivot
pivot.scale = (2 / extent,) * 3

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 64
scene.cycles.use_denoising = True
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "CUDA"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = "GPU"
except Exception as exc:  # noqa: BLE001
    print("GPU not available:", exc)
scene.render.resolution_x = scene.render.resolution_y = size
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"

world = bpy.data.worlds.new("w")
scene.world = world
world.use_nodes = True
bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
# Background as in the README pictures (25, 26, 30); lighting from the sun lamps.
bg.inputs[0].default_value = (0.0097, 0.0103, 0.0116, 1)
bg.inputs[1].default_value = 1.0

def light(name, direction, energy):
    data = bpy.data.lights.new(name, "SUN")
    data.energy = energy
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.rotation_euler = Vector(direction).to_track_quat("Z", "Y").to_euler()

light("key", (0.6, -0.8, 0.9), 3.5)
light("fill", (-0.8, -0.4, 0.4), 1.4)
light("rim", (0.0, 1.0, 0.6), 1.8)
light("top", (0.0, 0.0, 1.0), 0.8)

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.5
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
direction = Vector((0, -1, 0.45)).normalized()
cam.location = direction * 6
cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()

for i in range(frames):
    pivot.rotation_euler = (0, 0, 2 * math.pi * i / frames)
    scene.render.filepath = f"{out_dir}/f{i:03d}.png"
    bpy.ops.render.render(write_still=True)
print("done")
