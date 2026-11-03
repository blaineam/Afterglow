# The app icon: an 80s sunset over a neon grid, drawn rather than painted so it can be tuned.
#
#   python3 Tools/make_icon.py
#
# Writes Assets/_Project/Branding/AppIcon.png at 1024, which ProjectSetup hands to both platforms.
# Needs Pillow: python3 -m pip install --user pillow
#
# It is built to survive being shrunk: few, bold grid lines and a sun whose slits widen downward,
# because at 60 points on a home screen a fine grid turns to mush.
from PIL import Image, ImageDraw, ImageFilter, ImageChops
from pathlib import Path
import math

OUT = Path(__file__).resolve().parent.parent / "Assets/_Project/Branding/AppIcon.png"

S = 1024
HORIZON = int(S * 0.60)

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

base = Image.new("RGB", (S, S), (0, 0, 0))
d = ImageDraw.Draw(base)

SKY_TOP, SKY_HORIZON = (0x16, 0x02, 0x33), (0x7A, 0x0E, 0x6B)
for y in range(HORIZON):
    d.line([(0, y), (S, y)], fill=lerp(SKY_TOP, SKY_HORIZON, (y / HORIZON) ** 1.7))
GND_H, GND_B = (0x29, 0x03, 0x37), (0x06, 0x00, 0x10)
for y in range(HORIZON, S):
    d.line([(0, y), (S, y)], fill=lerp(GND_H, GND_B, ((y - HORIZON) / (S - HORIZON)) ** 0.7))

# --- the sun, sitting ON the horizon: everything below it is simply not drawn ---
R = int(S * 0.255)
CX, CY = S // 2, HORIZON - int(R * 0.34)
sun = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sun)
SUN_TOP, SUN_BOT = (0xFF, 0xE9, 0x5C), (0xFF, 0x1E, 0x6F)
for y in range(CY - R, min(CY + R, HORIZON) + 1):
    half = math.sqrt(max(0.0, R*R - (y - CY)**2))
    t = (y - (CY - R)) / (2 * R)
    sd.line([(CX - half, y), (CX + half, y)], fill=lerp(SUN_TOP, SUN_BOT, t) + (255,))

# Slits across the visible disc, thin at the top and widening toward the horizon -- few and bold,
# so they survive being shrunk to a home-screen icon.
y = CY - int(R * 0.10)
h = R * 0.035
while y < HORIZON:
    sd.rectangle([CX - R - 6, y, CX + R + 6, y + max(3, int(h))], fill=(0, 0, 0, 0))
    y += int(h) + int(R * 0.115); h *= 1.5
base.paste(sun, (0, 0), sun)

# Glow, added rather than blended so the sun blooms into the sky.
glow = Image.new("RGB", (S, S), (0, 0, 0))
ImageDraw.Draw(glow).ellipse([CX-R, CY-R, CX+R, min(CY+R, HORIZON)], fill=(0xFF, 0x2E, 0x7A))
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.085)).point(lambda v: int(v * 0.75))
base = ImageChops.add(base, glow)
d = ImageDraw.Draw(base)

# --- the grid: bold and sparse, so it still reads small ---
CYAN = (0x0A, 0xE8, 0xF0)
VP = (S // 2, HORIZON)
for i in range(-9, 10):
    d.line([VP, (VP[0] + i * (S * 0.235), S + 40)], fill=CYAN, width=5 if i % 3 == 0 else 3)
z = 0.10
while z < 1.0:
    y = HORIZON + (S - HORIZON) * (z ** 1.9)
    d.line([(0, y), (S, y)], fill=CYAN, width=3 if z < 0.35 else 6)
    z += 0.10 + z * 0.22

# Horizon flash, over the grid so it stays crisp.
d.line([(0, HORIZON), (S, HORIZON)], fill=(0xFF, 0xF6, 0xDC), width=6)
d.line([(0, HORIZON), (S, HORIZON)], fill=(0xFF, 0xB8, 0xE6), width=2)

OUT.parent.mkdir(parents=True, exist_ok=True)
base.save(OUT)
print(f"wrote {OUT}")
