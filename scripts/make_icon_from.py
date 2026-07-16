#!/usr/bin/env python3
"""Convert a source PNG into AppIcon.icns (macOS iconset). Usage: make_icon_from.py <src.png>"""
import os, sys, subprocess, tempfile
from PIL import Image

src = sys.argv[1]
out_dir = os.path.join(os.path.dirname(__file__), "..", "app")
icns = os.path.join(out_dir, "AppIcon.icns")

img = Image.open(src).convert("RGBA")
# force square 1024 base (in case source isn't perfectly square)
size = 1024
img = img.resize((size, size), Image.LANCZOS)

with tempfile.TemporaryDirectory() as td:
    iset = os.path.join(td, "AppIcon.iconset")
    os.makedirs(iset, exist_ok=True)
    for s in [16, 32, 128, 256, 512]:
        img.resize((s, s), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}.png"))
        img.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iset, f"icon_{s}x{s}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iset, "-o", icns], check=True)
print("icns:", icns, "(%d bytes)" % os.path.getsize(icns))
