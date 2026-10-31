"""Draws the super zombie skins from the game's own zombie bodies: greyscale, then a colour wash. Run once; needs Pillow."""
from PIL import Image, ImageOps

SRC = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/textures/Body/%s_ZedBody01_level1.png"
OUT = "ServerEventManager/Contents/mods/ServerEventManager/42/media/textures/Body/SEM_%s_%s.png"
WASH = {"Mutant": ("#061a02", "#3fd60c", "#d8ff5a"), "Boss": ("#1a0202", "#e01010", "#ffb060")}

for name, (black, mid, white) in WASH.items():
    for sex in ("M", "F"):
        im = Image.open(SRC % sex).convert("RGBA")
        skin = ImageOps.colorize(ImageOps.autocontrast(im.convert("L")), black=black, mid=mid, white=white).convert("RGBA")
        skin.putalpha(im.getchannel("A"))
        skin.save(OUT % (name, sex))
