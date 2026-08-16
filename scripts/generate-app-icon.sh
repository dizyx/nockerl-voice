#!/usr/bin/env bash
#
# generate-app-icon.sh - regenerate every AppIcon PNG from the vendored Voice mark.
#
# WHY THIS EXISTS. The icon PNGs used to be produced by hand. That is how a centering
# bug baked itself in silently: the glyph sat well above the middle of the plate in
# every size at once, and because there was no way to regenerate them, nobody could
# see it drift. Now the whole ladder comes from one command, and the script MEASURES
# what it produced and prints the numbers, so a regression is visible immediately
# instead of shipping.
#
# SOURCE OF TRUTH is the on-dark mark under art/. Change it and re-run this; every
# size follows. The on-dark variant is the correct one because the icon plate is dark.
#
# COMPOSITION (all proportional, so every size is identical apart from resolution):
#   plate  80.1% of the canvas, centred. This is the Apple convention (a macOS icon
#          does not fill its canvas; the margin is where the system draws shadow).
#   corner 22.4% of the plate width, a plain circular arc. Both numbers were measured
#          off the existing 1024px asset, so the plate is reproduced exactly as it
#          shipped. A circular arc fits the original to 0.43px RMS; a superellipse
#          does not fit, so the corner is a plain rounded rect, not a squircle.
#   glyph  70% of the plate height, centred. 70% is deliberate and is NOT the same
#          proportion the mark uses elsewhere in the app: in-app surfaces run the
#          glyph at 90% of its box, but an app icon needs breathing room inside the
#          plate, and a 90% glyph reads as crowded at Dock size.
#
# Usage: bash scripts/generate-app-icon.sh
# Idempotent: running it twice produces byte-identical PNGs.
#
# Requires rsvg-convert (librsvg) and python3 with Pillow, both used for rendering
# and for the verification pass at the end.
set -euo pipefail

cd "$(dirname "$0")/.."

# DO NOT DELETE THIS FILE AS "UNUSED ART". Nothing renders it at runtime, and that is
# the point: the app's runtime marks now come from the NockerlDesign package, resolved
# from Bundle.module. An app ICON cannot. It is compiled into the app bundle from the
# target's own asset catalog at build time, so it needs a local source, and this is it.
# It lives under art/ rather than in Assets.xcassets precisely so it does not look like
# a catalog entry that nothing renders, which is exactly what a later cleanup sweep
# would delete, silently breaking the icon build.
MARK="art/voice-on-dark.svg"
ICONSET="NockerlVoice/Assets.xcassets/AppIcon.appiconset"
CONTENTS="$ICONSET/Contents.json"

# Proportions, measured off the shipped 1024px asset. See the header.
PLATE_FRAC=0.80078125     # 410/512
CORNER_FRAC=0.224         # of the plate width
GLYPH_H_FRAC=0.70         # glyph height as a fraction of the plate
PLATE_COLOR="#15171A"

for tool in rsvg-convert python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required but not installed." >&2; exit 1; }
done
python3 -c "import PIL" 2>/dev/null || { echo "error: python3 Pillow is required." >&2; exit 1; }
[[ -f "$MARK" ]] || { echo "error: mark not found at $MARK" >&2; exit 1; }
[[ -f "$CONTENTS" ]] || { echo "error: $CONTENTS not found" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Build the master icon SVG at 1024, then rasterise it down to every required size.
# The mark is embedded as a NESTED svg so its own tight viewBox does the centering
# work: the glyph is centred inside its viewBox, so centring the nested box centres
# the glyph. Its inner markup is lifted verbatim from the vendored file, which is why
# a future mark change needs no edit here.
# How much of its own viewBox does the artwork actually fill vertically? MEASURE it,
# never assume it. This was hardcoded at 0.90, which silently stopped being true the
# moment the design fleet re-cropped the marks full bleed (0.995): the glyph then
# rendered at 0.70/0.90*0.995 = 77% of the plate instead of the intended 70%. Probing
# the real art makes the generator self-correcting for any future re-crop.
rsvg-convert -w 512 -h 512 "$MARK" -o "$WORK/probe.png"
ARTWORK_H=$(python3 - "$WORK/probe.png" <<'PY'
import sys
from PIL import Image
import numpy as np
a = np.array(Image.open(sys.argv[1]).convert("RGBA"))[:, :, 3]
ys, _ = np.nonzero(a > 8)
if len(ys) == 0:
    sys.exit("error: the mark rendered empty")
print(f"{(ys.max() - ys.min() + 1) / a.shape[0]:.6f}")
PY
)
echo "    measured artwork fill: ${ARTWORK_H} of its own viewBox height"

python3 - "$MARK" "$WORK/icon.svg" "$PLATE_FRAC" "$CORNER_FRAC" "$GLYPH_H_FRAC" "$PLATE_COLOR" "$ARTWORK_H" <<'PY'
import re, sys
mark_path, out_path, plate_frac, corner_frac, glyph_h_frac, plate_color, artwork_h = sys.argv[1:8]
plate_frac, corner_frac, glyph_h_frac = float(plate_frac), float(corner_frac), float(glyph_h_frac)
artwork_h = float(artwork_h)

src = open(mark_path, encoding="utf-8").read()

# The mark's own viewBox is tight around the artwork, and the artwork fills 90% of that
# box vertically. Read it rather than assuming it, so this keeps working if the mark is
# re-cropped upstream.
m = re.search(r'viewBox="([^"]+)"', src)
if not m:
    sys.exit("error: the mark has no viewBox")
view_box = m.group(1)

# Inner markup only: drop the outer <svg ...> open tag and its closing tag.
inner = re.sub(r'^.*?<svg\b[^>]*>', '', src, count=1, flags=re.S)
inner = re.sub(r'</svg>\s*$', '', inner, flags=re.S).strip()

C = 1024.0
plate = C * plate_frac
plate_xy = (C - plate) / 2.0
corner = plate * corner_frac

# The artwork does not fill its own viewBox exactly, so to land the glyph at
# glyph_h_frac of the plate the nested box is scaled by the MEASURED fill fraction
# passed in above. Measured, not assumed: see the note at the probe step.
box = plate * (glyph_h_frac / artwork_h)
box_xy = (C - box) / 2.0

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{C:.0f}" height="{C:.0f}" viewBox="0 0 {C:.0f} {C:.0f}">
  <rect x="{plate_xy:.4f}" y="{plate_xy:.4f}" width="{plate:.4f}" height="{plate:.4f}" rx="{corner:.4f}" ry="{corner:.4f}" fill="{plate_color}"/>
  <svg x="{box_xy:.4f}" y="{box_xy:.4f}" width="{box:.4f}" height="{box:.4f}" viewBox="{view_box}">
{inner}
  </svg>
</svg>
'''
open(out_path, "w", encoding="utf-8").write(svg)
PY

# Render every entry the catalog actually declares. Enumerated from Contents.json so
# the script cannot drift from the catalog: add a size there and it is picked up here.
mapfile -t JOBS < <(python3 - "$CONTENTS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
seen = set()
for i in d["images"]:
    fn = i.get("filename")
    if not fn or fn in seen:
        continue
    seen.add(fn)
    px = int(float(i["size"].split("x")[0]) * int(i["scale"].rstrip("x")))
    print(f"{px}\t{fn}")
PY
)

echo "==> regenerating ${#JOBS[@]} PNGs from $MARK"
for job in "${JOBS[@]}"; do
  px="${job%%$'\t'*}"; fn="${job##*$'\t'}"
  rsvg-convert -w "$px" -h "$px" "$WORK/icon.svg" -o "$ICONSET/$fn"
  printf '    %-24s %sx%s\n' "$fn" "$px" "$px"
done

# Verification. The point of the script: prove what it produced rather than assert it.
echo "==> measured result"
python3 - "$ICONSET" <<'PY'
import sys, glob, os
import numpy as np
from PIL import Image

iconset = sys.argv[1]
plate_rgb = np.array([0x15, 0x17, 0x1A])
plate_lum = float(plate_rgb @ np.array([0.299, 0.587, 0.114]))
worst = 0.0

for path in sorted(glob.glob(os.path.join(iconset, "*.png")), key=lambda p: os.path.getsize(p)):
    im = np.array(Image.open(path).convert("RGBA")).astype(int)
    H, W, _ = im.shape
    a = im[:, :, 3]
    ys, xs = np.nonzero(a > 128)
    if not len(xs):
        print(f"    {os.path.basename(path):<24} EMPTY"); continue
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    pw, ph = x1 - x0 + 1, y1 - y0 + 1
    lum = im[:, :, :3] @ np.array([0.299, 0.587, 0.114])
    # The glyph is whatever is clearly brighter than the plate. Corner antialiasing is
    # darker than the plate, so this does not mistake the rounded corners for artwork.
    gy, gx = np.nonzero((a > 200) & (lum > plate_lum + 40))
    if not len(gx):
        print(f"    {os.path.basename(path):<24} plate {100*pw/W:5.1f}%  (too small to measure the glyph)")
        continue
    gw, gh = gx.max() - gx.min() + 1, gy.max() - gy.min() + 1
    dx = (gx.min() + gx.max() + 1) / 2 - (x0 + x1 + 1) / 2
    dy = (gy.min() + gy.max() + 1) / 2 - (y0 + y1 + 1) / 2
    # Express the offset relative to the plate so it is comparable across sizes.
    rel = max(abs(dx), abs(dy)) / pw * 100
    worst = max(worst, rel)
    print(f"    {os.path.basename(path):<24} canvas {W:>4}  plate {100*pw/W:5.1f}%  "
          f"glyph {100*gw/pw:5.1f}%w x {100*gh/ph:5.1f}%h of plate  offset {dx:+5.1f},{dy:+5.1f}px")

print(f"    worst glyph offset across all sizes: {worst:.2f}% of the plate")
print("    expected: plate 80.1% of canvas, glyph about 70% of plate height, offset near zero")
PY
