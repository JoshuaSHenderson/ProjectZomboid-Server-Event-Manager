# glb -> Project Zomboid vehicle-model FBX for the Aircraft Crash wrecks (Blender 3.6, run headless):
#   blender -b --python tools/convert-model.py -- key=value ...
# keys: src= (glb), out= (fbx), tex= (png written), tris= (decimate target),
#   keep=<object name part> with img=<image name in the glb, or a png path>   one object, its own texture, or
#   keep=ALL with imgs=<image>,<image>,...                                    every object joined, one per object
#                                                                             (sorted by name), textures on a 2x2 atlas
#   rotate=<degrees about the up axis, applied first>  brighten=<target mean 0-255, 0 = off>  size=<texture px, 1024>
#   shift=<x>,<y> metres from the bounding-box centre to the new origin: put the origin on the main body, because the
#   vehicle's collision box is centred on the origin (the plane's body is off-centre among its scattered pieces)
# Commands used for the shipped wrecks: see the header of media/scripts/ServerEventManager/vehicles_sem_crash.txt.
# The mesh is centred on its bounding box, triangulated and written with the axis turn baked into the vertices
# (a rotation left on the file's nodes made it invisible in game). The baked export writes Blender metres as centimetres;
# the model script's scale = 0.01 brings them back to metres. Do not scale the mesh here (that made the wrecks 100x too big).
import bpy, sys, os, math, mathutils
import numpy as np

arg = dict(s.split("=", 1) for s in sys.argv[sys.argv.index("--") + 1:])
for k in ("src", "out", "tex"): arg[k] = os.path.abspath(arg[k])  # Blender silently skips saving to a relative path
size = int(arg.get("size", 1024))
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=arg["src"])
meshes = sorted([o for o in bpy.data.objects if o.type == 'MESH'], key=lambda o: o.name)
keep = meshes if arg["keep"] == "ALL" else [m for m in meshes if arg["keep"] in m.name][:1]
for m in meshes:
    if m not in keep: bpy.data.objects.remove(m)
for e in [x for x in bpy.data.objects if x.type != 'MESH']: bpy.data.objects.remove(e)  # parents go; matrices baked below


def pixels(src):
    """float RGBA rows (bottom-up, as Blender stores them) of a glb image or png path, resized to size x size"""
    img = bpy.data.images.get(src) or bpy.data.images.load(src)
    img = img.copy()
    img.scale(size, size)
    px = np.empty(size * size * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return px.reshape(size, size, 4)


def brighten(px, target):
    """gamma lift of RGB until the mean is target/255; black stays black, white stays white"""
    rgb = np.clip(px[..., :3], 0, 1)
    lo, hi = 0.05, 1.0
    for _ in range(25):
        g = (lo + hi) / 2
        if (rgb ** g).mean() * 255 < target: hi = g
        else: lo = g
    px[..., :3] = rgb ** ((lo + hi) / 2)
    return px


target = float(arg.get("brighten", 0))
srcs = arg["imgs"].split(",") if "imgs" in arg else [arg["img"]]
assert len(srcs) == len(keep), "one image per kept object"
tiles = [brighten(pixels(s), target) if target > 0 else pixels(s) for s in srcs]
atlas = len(keep) > 1
QUAD = [(0, 1), (1, 1), (0, 0), (1, 0)]  # UV quadrants (u, v), Blender UV space: origin bottom left
for i, o in enumerate(keep):
    o.data.transform(o.matrix_world); o.matrix_world = mathutils.Matrix.Identity(4)
    if atlas:
        qx, qy = QUAD[i]
        uv = o.data.uv_layers.active.data
        us = [d.uv[0] for d in uv]; vs = [d.uv[1] for d in uv]
        if min(us) < 0 or max(us) > 1 or min(vs) < 0 or max(vs) > 1:
            print("WARN uv outside 0..1 on", o.name, round(min(us), 3), round(max(us), 3), round(min(vs), 3), round(max(vs), 3))
        for d in uv:
            d.uv = ((min(max(d.uv[0], 0), 1) + qx) / 2, (min(max(d.uv[1], 0), 1) + qy) / 2)
for o in keep: o.select_set(True)
bpy.context.view_layer.objects.active = keep[0]
if len(keep) > 1: bpy.ops.object.join()
o = bpy.context.view_layer.objects.active
if "rotate" in arg: o.data.transform(mathutils.Matrix.Rotation(math.radians(float(arg["rotate"])), 4, 'Z'))
d = o.dimensions
if "rotate" not in arg and d.x > d.y: o.data.transform(mathutils.Matrix.Rotation(math.pi / 2, 4, 'Z'))  # length on Y
pts = [v.co for v in o.data.vertices]
c = mathutils.Vector([(min(p[i] for p in pts) + max(p[i] for p in pts)) / 2 for i in range(3)])
if "shift" in arg:  # metres from the bounding-box centre to the point that becomes the origin (the main body), after rotate
    sx, sy = (float(v) for v in arg["shift"].split(","))
    c.x += sx; c.y += sy
o.data.transform(mathutils.Matrix.Translation(-c))
o.data.update()
n = sum(len(f.vertices) - 2 for f in o.data.polygons)
tris = int(arg.get("tris", 8000))
if n > tris:
    md = o.modifiers.new("d", 'DECIMATE'); md.ratio = tris / n
    bpy.ops.object.modifier_apply(modifier="d")
md = o.modifiers.new("t", 'TRIANGULATE'); bpy.ops.object.modifier_apply(modifier="t")
print("RESULT", os.path.basename(arg["out"]), sum(len(f.vertices) - 2 for f in o.data.polygons), "tris, size m",
      [round(x, 2) for x in o.dimensions])
bpy.ops.export_scene.fbx(filepath=arg["out"], use_selection=True, object_types={'MESH'}, apply_scale_options='FBX_SCALE_NONE',
                         apply_unit_scale=False, global_scale=1.0, bake_space_transform=True, mesh_smooth_type='FACE',
                         bake_anim=False, path_mode='STRIP')
if atlas:
    out = np.zeros((2 * size, 2 * size, 4), dtype=np.float32); out[..., 3] = 1
    for i, t in enumerate(tiles):
        qx, qy = QUAD[i]
        out[qy * size:(qy + 1) * size, qx * size:(qx + 1) * size] = t
    w = 2 * size
else:
    out, w = tiles[0], size
img = bpy.data.images.new("tex", w, w)
img.pixels.foreach_set(out.ravel())
img.filepath_raw = arg["tex"]; img.file_format = 'PNG'; img.save()
assert os.path.isfile(arg["tex"]), "texture not written: " + arg["tex"]
print("TEX", arg["tex"], w)
