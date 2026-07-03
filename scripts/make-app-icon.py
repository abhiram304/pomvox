#!/usr/bin/env python3
"""
make-app-icon.py — generate Pomvox's app icon from the app's own theme.

The icon is the brand in one glance: a warm espresso squircle (the dark `pane`)
with a glowing ember waveform (Palette.ember → gold), echoing the in-app Waveform
component. Colors are lifted straight from DesignSystem.swift so the icon and the
UI can never drift. Rendered 4× supersampled, then downscaled with Lanczos to
every macOS icon size — crisp at 16 px and 1024 px alike.

    python3 scripts/make-app-icon.py

Writes the full AppIcon set into Pomvox/Sources/Assets.xcassets/AppIcon.appiconset/
and a preview PNG next to this script's output dir.
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

# ── theme (from DesignSystem.swift Palette) ──────────────────────────────────
def rgb(h): return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

BG_TOP    = rgb("33231A")   # warm espresso, lifted from pane(dark) 1B1813
BG_BOT    = rgb("140E09")
EMBER_HI  = rgb("FF8551")   # between ember light CF4F27 and dark F4703F, brightened
EMBER_LO  = rgb("D8552A")
GOLD      = rgb("D8A851")   # Palette.gold(dark)
GLOW      = rgb("F4703F")   # Palette.ember(dark)

S = 1024            # nominal icon size
SS = 4              # supersample factor
R = S * SS          # render size
def px(v): return int(round(v * SS))   # nominal → render px

OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Pomvox", "Sources", "Assets.xcassets", "AppIcon.appiconset")
OUT = os.path.normpath(OUT)


def vgrad(w, h, top, bot):
    """Vertical gradient as an RGBA image."""
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        col.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return col.resize((w, h)).convert("RGBA")


def rounded_mask(w, h, box, radius):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def render():
    img = Image.new("RGBA", (R, R), (0, 0, 0, 0))

    # macOS icon grid: ~10% margin (the shadow lives in it), squircle corners.
    margin = px(100)
    box = (margin, margin, R - margin, R - margin)
    side = box[2] - box[0]
    radius = int(side * 0.2237)   # Apple's rounded-rect proportion

    # 1) soft drop shadow under the tile
    sh = Image.new("RGBA", (R, R), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        (box[0], box[1] + px(14), box[2], box[3] + px(14)),
        radius=radius, fill=(0, 0, 0, 110))
    sh = sh.filter(ImageFilter.GaussianBlur(px(22)))
    img.alpha_composite(sh)

    # 2) the espresso tile
    tile_mask = rounded_mask(R, R, box, radius)
    img.paste(vgrad(R, R, BG_TOP, BG_BOT), (0, 0), tile_mask)

    # subtle top sheen so the tile isn't flat
    sheen = Image.new("RGBA", (R, R), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse((box[0] - px(60), box[1] - px(260), box[2] + px(60), box[1] + px(360)),
               fill=(255, 240, 220, 26))
    sheen.putalpha(Image.composite(sheen.getchannel("A"),
                                   Image.new("L", (R, R), 0), tile_mask))
    img.alpha_composite(sheen.filter(ImageFilter.GaussianBlur(px(40))))

    # 3) the waveform — 5 rounded bars, symmetric envelope
    cx, cy = R // 2, R // 2
    bar_w = px(72)
    gap = px(40)
    env = [0.20, 0.34, 0.50, 0.34, 0.20]   # height as fraction of S
    n = len(env)
    total = n * bar_w + (n - 1) * gap
    x0 = cx - total // 2

    bars_mask = Image.new("L", (R, R), 0)
    bd = ImageDraw.Draw(bars_mask)
    for i, e in enumerate(env):
        x = x0 + i * (bar_w + gap)
        h = px(S * e)
        bd.rounded_rectangle((x, cy - h // 2, x + bar_w, cy + h // 2),
                             radius=bar_w // 2, fill=255)

    # ember glow behind the bars
    glow = Image.new("RGBA", (R, R), (0, 0, 0, 0))
    glow.paste(Image.new("RGBA", (R, R), GLOW + (255,)), (0, 0), bars_mask)
    glow = glow.filter(ImageFilter.GaussianBlur(px(34)))
    glow.putalpha(glow.getchannel("A").point(lambda a: int(a * 0.55)))
    img.alpha_composite(glow)

    # the bars themselves, ember→ a warm gold-tipped gradient
    bars = vgrad(R, R, EMBER_HI, EMBER_LO)
    # warm the very top toward gold for a glowing-tip feel
    tip = vgrad(R, R, GOLD, EMBER_HI)
    bars = Image.composite(tip, bars, Image.new("L", (R, R), 60))
    img.paste(bars, (0, 0), bars_mask)

    return img.resize((S, S), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        master.resize((s, s), Image.LANCZOS).save(os.path.join(OUT, f"icon_{s}.png"))

    contents = {"images": [], "info": {"version": 1, "author": "xcode"}}
    grid = [("16x16", "1x", 16), ("16x16", "2x", 32),
            ("32x32", "1x", 32), ("32x32", "2x", 64),
            ("128x128", "1x", 128), ("128x128", "2x", 256),
            ("256x256", "1x", 256), ("256x256", "2x", 512),
            ("512x512", "1x", 512), ("512x512", "2x", 1024)]
    for size, scale, px_ in grid:
        contents["images"].append(
            {"idiom": "mac", "size": size, "scale": scale, "filename": f"icon_{px_}.png"})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)

    # top-level catalog Contents.json (create if missing)
    cat = os.path.dirname(OUT)
    cat_contents = os.path.join(cat, "Contents.json")
    if not os.path.exists(cat_contents):
        with open(cat_contents, "w") as f:
            json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)

    master.save("/tmp/pomvox-icon-preview.png")
    print(f"wrote {len(sizes)} pngs + Contents.json → {OUT}")
    print("preview → /tmp/pomvox-icon-preview.png")


if __name__ == "__main__":
    main()
