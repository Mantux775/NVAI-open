# blender -b --factory-startup -P render_glb.py -- <in.glb> <out_dir> [solid]
# Renders a GLB from four directions with its own materials (or plain grey with "solid").
import math
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_dir = argv[0], argv[1]
solid = len(argv) > 2 and argv[2] == "solid"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]

# Bounds over all meshes, then centre at the origin and scale to 2 units.
pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
center, size = (lo + hi) / 2, max(hi - lo)
roots = [o for o in bpy.context.scene.objects if o.parent is None]
pivot = bpy.data.objects.new("pivot", None)
bpy.context.scene.collection.objects.link(pivot)
for o in roots:
    o.parent = pivot
pivot.location = -center * (2 / size)
pivot.scale = (2 / size,) * 3

if solid:
    grey = bpy.data.materials.new("grey")
    grey.diffuse_color = (0.55, 0.55, 0.55, 1)
    for o in meshes:
        o.data.materials.clear()
        o.data.materials.append(grey)

scene = bpy.context.scene
engines = [i.identifier for i in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
scene.render.engine = "CYCLES" if "CYCLES" in engines else engines[0]
if scene.render.engine == "CYCLES":
    scene.cycles.samples = 96
    scene.cycles.use_denoising = True
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "CUDA"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception as exc:  # noqa: BLE001 - CPU works too, just slower
        print("GPU not available:", exc)
scene.render.resolution_x = scene.render.resolution_y = 640
scene.render.film_transparent = True
scene.view_settings.view_transform = "Standard"

world = bpy.data.worlds.new("w")
world.use_nodes = True
bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
bg.inputs[0].default_value = (0.8, 0.8, 0.82, 1)
bg.inputs[1].default_value = 0.6
scene.world = world

def light(name, direction, energy):
    data = bpy.data.lights.new(name, "SUN")
    data.energy = energy
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.rotation_euler = Vector(direction).to_track_quat("Z", "Y").to_euler()

light("key", (0.6, -0.8, 0.9), 3.0)
light("fill", (-0.8, -0.3, 0.4), 1.0)
light("rim", (0.0, 1.0, 0.6), 1.5)

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.6
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

# glTF is Y-up, Blender imports it Z-up: front of the model looks along -Y.
views = {"front": (0, -1, 0.05), "right": (1, 0, 0.05), "back": (0, 1, 0.05),
         "three_quarter": (0.75, -0.9, 0.55)}
for name, d in views.items():
    direction = Vector(d).normalized()
    cam.location = direction * 6
    cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = f"{out_dir}/{name}.png"
    bpy.ops.render.render(write_still=True)
print("done")
