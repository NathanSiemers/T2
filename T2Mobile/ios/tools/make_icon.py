#!/usr/bin/env python3
"""Draws the T2 app icon and the launch-screen logo (needs Pillow).

    python3 T2Mobile/ios/tools/make_icon.py          # run from the repository root

Writes
    T2App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png   (1024 px, no alpha)
    T2App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo*.png   (transparent)
The pictures are committed; this script only has to be run to change them.
The motif is what the app does: a scatter of samples in the plasma palette T2 uses, with
its fit line, on the palette's dark end.
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "T2App", "Resources", "Assets.xcassets")
FONT = os.path.join(HERE, "..", "..", "..", "fonts", "LiberationSans-Bold.ttf")

# anchors of viridis' "plasma" map
PLASMA = [(13, 8, 135), (84, 2, 163), (139, 10, 165), (185, 50, 137),
          (219, 92, 104), (244, 136, 73), (254, 188, 43), (240, 249, 33)]


def plasma(t):
    t = min(max(t, 0.0), 1.0) * (len(PLASMA) - 1)
    i = min(int(t), len(PLASMA) - 2)
    f = t - i
    return tuple(round(PLASMA[i][k] + f * (PLASMA[i + 1][k] - PLASMA[i][k])) for k in range(3))


def draw(size, background=True, text=True):
    s = 4                                   # supersampling
    n = size * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    if background:
        top, bottom = (22, 12, 110), (64, 4, 130)
        grad = Image.new("RGB", (1, n))
        for y in range(n):
            f = y / (n - 1)
            grad.putpixel((0, y), tuple(round(top[k] + f * (bottom[k] - top[k])) for k in range(3)))
        img = grad.resize((n, n)).convert("RGBA")
    d = ImageDraw.Draw(img, "RGBA")
    u = n / 1024.0
    rnd = random.Random(7)
    # samples around a rising line; colour follows the value, as "color by" does
    pts = []
    for _ in range(46):
        x = rnd.uniform(0.14, 0.90)
        y = 0.20 + 0.56 * (x - 0.14) / 0.76 + rnd.gauss(0, 0.085)
        pts.append((x, min(max(y, 0.10), 0.92)))
    for x, y in pts:
        if text and x < 0.56 and y > 0.56:      # keep the lettering's corner clear
            continue
        r = rnd.uniform(20, 30) * u
        cx, cy = x * n, (1 - y) * n
        c = plasma(0.30 + 0.70 * y)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c + (235,))
    # fit line
    d.line([(0.12 * n, (1 - 0.185) * n), (0.92 * n, (1 - 0.775) * n)], fill=(255, 255, 255, 235),
           width=round(15 * u))
    if text:
        font = ImageFont.truetype(FONT, round(330 * u))
        d.text((0.105 * n, 0.085 * n), "T2", font=font, fill=(255, 255, 255, 255))
    return img.resize((size, size), Image.LANCZOS)


def main():
    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    logo_dir = os.path.join(ASSETS, "LaunchLogo.imageset")
    os.makedirs(icon_dir, exist_ok=True)
    os.makedirs(logo_dir, exist_ok=True)
    draw(1024).convert("RGB").save(os.path.join(icon_dir, "AppIcon-1024.png"), optimize=True)
    # the launch logo: the icon itself with rounded corners, at 1x / 2x / 3x of 120 pt
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        px = 120 * scale
        logo = draw(px * 2).resize((px, px), Image.LANCZOS)
        mask = Image.new("L", (px * 4, px * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * 4 - 1, px * 4 - 1], radius=round(px * 4 * 0.225), fill=255)
        logo.putalpha(mask.resize((px, px), Image.LANCZOS))
        logo.save(os.path.join(logo_dir, "LaunchLogo%s.png" % suffix), optimize=True)
    print("wrote", os.path.normpath(icon_dir), "and", os.path.normpath(logo_dir))


if __name__ == "__main__":
    main()
