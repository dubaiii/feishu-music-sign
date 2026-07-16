#!/usr/bin/env python3
"""Convert a source PNG into AppIcon.icns, cropping tight to content and filling
edge-to-edge so macOS's squircle mask doesn't leave it looking un-filled.
Usage: make_icon_from.py <src.png> [--pad N]   (pad = % safe margin around content, default 2)
"""
import os, sys, subprocess, tempfile
from PIL import Image

src = sys.argv[1]
pad_pct = 2
if "--pad" in sys.argv:
    pad_pct = int(sys.argv[sys.argv.index("--pad") + 1])

out_dir = os.path.join(os.path.dirname(__file__), "..", "app")
icns = os.path.join(out_dir, "AppIcon.icns")

im = Image.open(src).convert("RGBA")
W, H = im.size

# 1) find non-(near-white) content bbox, sample-stride for speed
px = im.load()
minx, miny, maxx, maxy = W, H, 0, 0
found = False
for y in range(0, H, 4):
    for x in range(0, W, 4):
        r, g, b, a = px[x, y]
        if a < 250 or r < 245 or g < 245 or b < 245:
            found = True
            if x < minx: minx = x
            if y < miny: miny = y
            if x > maxx: maxx = x
            if y > maxy: maxy = y
if not found:
    raise SystemExit("image looks blank")

# expand bbox back to full pixels (stride 4 sampled) + a tiny pad so we don't clip
pad = int(max(W, H) * pad_pct / 100)
minx = max(0, minx - pad); miny = max(0, miny - pad)
maxx = min(W - 1, maxx + pad); maxy = min(H - 1, maxy + pad)
cw, ch = maxx - minx, maxy - miny
# make it square (center-crop to the larger side)
side = max(cw, ch)
cx, cy = (minx + maxx) // 2, (miny + maxy) // 2
half = side // 2
sx0 = max(0, cx - half); sy0 = max(0, cy - half)
sx1 = min(W, sx0 + side); sy1 = min(H, sy0 + side)
# adjust if we hit an edge
side = min(sx1 - sx0, sy1 - sy0)
sx1 = sx0 + side; sy1 = sy0 + side
im = im.crop((sx0, sy0, sx1, sy1))

# 2) scale to 1024 edge-to-edge, then enlarge by `zoom` so content bleeds past the
#    canvas edges (macOS squircle mask clips the overflow -> visually larger fill).
zoom = 1.40
if "--zoom" in sys.argv:
    zoom = float(sys.argv[sys.argv.index("--zoom") + 1])
size = 1024
big = int(size * zoom)
im = im.resize((big, big), Image.LANCZOS)
# center-crop back to 1024
left = (big - size) // 2
top = (big - size) // 2
im = im.crop((left, top, left + size, top + size))

# 3) build iconset + icns
with tempfile.TemporaryDirectory() as td:
    iset = os.path.join(td, "AppIcon.iconset")
    os.makedirs(iset, exist_ok=True)
    for s in [16, 32, 128, 256, 512]:
        im.resize((s, s), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}.png"))
        im.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iset, "-o", icns], check=True)
print("icns:", icns, "(%d bytes)" % os.path.getsize(icns))
print("cropped content square side:", side, "-> 1024 full-bleed")
