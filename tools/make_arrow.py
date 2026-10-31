"""Draws the client's arrows (client/SEM/Arrows.lua): 16 directions, 0 east then clockwise, and the flat down chevrons over heads. Run once; needs Pillow."""
import math
from PIL import Image, ImageDraw

OUT = "ServerEventManager/Contents/mods/ServerEventManager/42/media/ui/SEM/%s.png"
SCALE, SIZE = 4, 48  # drawn large, then shrunk, for smooth edges
SHAPE = [(20, 0), (-14, -15), (-5, 0), (-14, 15)]


def draw(name, a, colour):
    c, s, mid = math.cos(a), math.sin(a), SIZE * SCALE / 2
    pts = [(mid + (x * c - y * s) * SCALE, mid + (x * s + y * c) * SCALE) for x, y in SHAPE]
    im = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.polygon(pts, fill=colour)
    d.line(pts + pts[:2], fill=(20, 10, 0, 255), width=3 * SCALE, joint="curve")
    im.resize((SIZE, SIZE), Image.LANCZOS).save(OUT % name)


for i in range(16):
    draw("arrow_%d" % i, i / 16 * 2 * math.pi, (255, 170, 30, 255))


def chevrons(name, colour):
    """Two stacked downward chevrons, flat, with a dark edge so they read against any ground."""
    im = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for width, fill in ((11, (15, 8, 0, 255)), (6, colour)):
        for top in (5, 19):
            pts = [(x * SCALE, y * SCALE) for x, y in ((6, top), (24, top + 18), (42, top))]
            d.line(pts, fill=fill, width=width * SCALE, joint="curve")
    im.resize((SIZE, SIZE), Image.LANCZOS).save(OUT % name)


chevrons("kill", (235, 25, 25, 255))
chevrons("friend", (40, 220, 70, 255))
