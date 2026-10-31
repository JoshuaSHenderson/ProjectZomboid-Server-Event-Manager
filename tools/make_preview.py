"""Draws ServerEventManager/preview.png, the Workshop image. Needs Pillow. Run from repo root."""
from PIL import Image, ImageDraw, ImageFont

SIZE = 256
EVENTS = ["Airdrop", "Hostile Camp", "Migrating Horde", "Wildfire", "Super Zombies", "Convoy Wreck"]


def font(px):
    try:
        return ImageFont.truetype("arialbd.ttf", px)
    except OSError:
        return ImageFont.load_default()


img = Image.new("RGB", (SIZE, SIZE), (12, 12, 12))
d = ImageDraw.Draw(img)
d.rectangle((6, 6, SIZE - 7, SIZE - 7), outline=(102, 102, 102))
d.rectangle((7, 7, SIZE - 8, 58), fill=(30, 30, 30))
d.line((7, 58, SIZE - 8, 58), fill=(102, 102, 102))
d.text((SIZE / 2, 22), "Server Event", font=font(19), fill=(255, 255, 255), anchor="mm")
d.text((SIZE / 2, 43), "Manager", font=font(19), fill=(255, 255, 255), anchor="mm")
y = 70
for i, name in enumerate(EVENTS):
    if i == 0:
        d.rectangle((8, y - 3, SIZE - 9, y + 23), fill=(90, 50, 25))
    d.text((18, y + 10), name, font=font(13), fill=(255, 255, 255), anchor="lm")
    on = i < 2
    colour = (115, 209, 77) if on else (178, 178, 178)
    d.rectangle((SIZE - 56, y + 1, SIZE - 18, y + 19), outline=colour)
    d.text((SIZE - 37, y + 10), "ON" if on else "OFF", font=font(10), fill=colour, anchor="mm")
    y += 29
img.resize((512, 512), Image.LANCZOS).save("ServerEventManager/preview.png")
