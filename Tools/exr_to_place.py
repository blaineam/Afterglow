# An EXR HDRI (equirectangular) to a 4096x2048 sRGB JPEG for ios-native/Afterglow/Places:
#   python3 -m venv venv && venv/bin/pip install OpenEXR numpy pillow
#   venv/bin/python -I Tools/exr_to_place.py in.exr ios-native/Afterglow/Places/name.jpg 1.0
# The last argument multiplies the exposure before an ACES filmic curve.
import sys, numpy as np, OpenEXR
from PIL import Image
src, dst, exposure = sys.argv[1], sys.argv[2], float(sys.argv[3])
with OpenEXR.File(src) as f:
    ch = f.channels()
    key = "RGBA" if "RGBA" in ch else "RGB"
    rgb = ch[key].pixels[..., :3] if key in ch else np.stack([ch[c].pixels for c in "RGB"], axis=-1)
rgb = rgb.astype(np.float32) * exposure
# ACES-style filmic tone map, then sRGB.
a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
t = np.clip((rgb * (a * rgb + b)) / (rgb * (c * rgb + d) + e), 0, 1)
srgb = np.where(t <= 0.0031308, 12.92 * t, 1.055 * np.power(t, 1 / 2.4) - 0.055)
img = Image.fromarray((srgb * 255 + 0.5).astype(np.uint8), "RGB")
print(src, img.size, "mean linear", float(rgb.mean()))
img = img.resize((4096, 2048), Image.LANCZOS)
img.save(dst, quality=85, subsampling=2, optimize=True)
