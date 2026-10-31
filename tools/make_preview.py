"""Draws ServerEventManager/preview.png, the Workshop image, in the console's own look. Needs Pillow. Run from repo root."""
from PIL import Image, ImageDraw, ImageFont

SIZE, SCALE = 256, 4  # drawn large, then shrunk, for smooth text
EVENTS = ["Airdrop", "Hostile Camp", "Migrating Horde", "Wildfire", "Super Zombies", "Convoy Wreck", "Under Siege", "Stranger Calls For Help", "Hunted"]
LINE, GREEN, HOT, RUST = (92, 92, 92), (115, 209, 77), (255, 255, 255), (96, 52, 24)


def font(px):
    try:
        return ImageFont.truetype("arialbd.ttf", px * SCALE)
    except OSError:
        return ImageFont.load_default()


def box(x1, y1, x2, y2):
    return (x1 * SCALE, y1 * SCALE, x2 * SCALE, y2 * SCALE)


img = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), (14, 14, 12))
d = ImageDraw.Draw(img)
d.rectangle(box(4, 4, SIZE - 5, 42), fill=(30, 29, 26))
d.rectangle(box(4, 4, SIZE - 5, SIZE - 5), outline=LINE, width=SCALE)
d.line(box(4, 42, SIZE - 5, 42), fill=LINE, width=SCALE)
d.text((13 * SCALE, 23 * SCALE), "Server Event Manager", font=font(15), fill=HOT, anchor="lm")
d.rectangle(box(SIZE - 52, 14, SIZE - 13, 32), outline=(235, 60, 40), width=SCALE)
d.text(((SIZE - 32.5) * SCALE, 23 * SCALE), "BETA", font=font(11), fill=(235, 60, 40), anchor="mm")

ROW, y = 22, 48
for i, name in enumerate(EVENTS):
    live = name == "Hunted"
    if live:
        d.rectangle(box(5, y, SIZE - 6, y + ROW - 2), fill=RUST)
    d.text((13 * SCALE, (y + 10) * SCALE), name, font=font(12), fill=HOT, anchor="lm")
    d.rectangle(box(SIZE - 46, y + 2, SIZE - 13, y + 18), outline=GREEN, width=SCALE)
    d.text(((SIZE - 29.5) * SCALE, (y + 10) * SCALE), "ON", font=font(10), fill=GREEN, anchor="mm")
    y += ROW
img.resize((SIZE, SIZE), Image.LANCZOS).save("ServerEventManager/preview.png")
