#!/usr/bin/env python3
"""Draws test media for the Simulator's Photos library, so the media browser and the player can be
checked without a phone or anyone's own photos:

  fixture-360-still.png   a 2:1 equirectangular still with FRONT, RIGHT, BACK and LEFT labeled, a
                          sky and a ground, so a 360 still is recognised by its shape and the
                          directions can be checked by looking around
  fixture-panorama.jpg    a 4:1 cylindrical panorama with a numbered post every 30 degrees of the
                          240 degrees it is meant to span, so the projection's angle can be judged
  fixture-flat.jpg        an ordinary 4:3 photo with a label, which belongs on the screen
  fixture-tall.jpg        a 3:4 portrait photo, which must come out upright

The spatial photo is made by make_spatial_photo.swift, since ImageIO is what writes a stereo pair.
Tools/sim_add_media.sh runs both and adds everything to the booted simulator.

  python3 Tools/make_fixture_media.py <output folder>
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def font(size):
    for name in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"):
        if os.path.exists(name):
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                pass
    return ImageFont.load_default()


def sky_and_ground(width, height, horizon):
    """A gradient sky above the horizon row and a darker ground below, as one image."""
    image = Image.new("RGB", (width, height))
    px = image.load()
    for y in range(height):
        if y < horizon:
            t = y / max(1, horizon)
            color = (int(30 + 90 * t), int(60 + 120 * t), int(140 + 90 * t))
        else:
            t = (y - horizon) / max(1, height - horizon)
            color = (int(70 - 30 * t), int(60 - 25 * t), int(50 - 20 * t))
        for x in range(width):
            px[x, y] = color
    return image


def label(draw, center, text, size, fill=(255, 255, 255)):
    f = font(size)
    box = draw.textbbox((0, 0), text, font=f)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text((center[0] - w / 2, center[1] - h / 2), text, font=f, fill=fill)


def still_360(path):
    w, h = 2048, 1024
    image = sky_and_ground(w, h, h // 2)
    draw = ImageDraw.Draw(image)
    # Longitude lines every 30 degrees, labeled at the horizon; the middle of the frame is ahead.
    for i in range(13):
        x = int(w * i / 12)
        draw.line([(x, 0), (x, h)], fill=(255, 255, 255, 60), width=2)
    for text, fraction in (("LEFT", 0.25), ("FRONT", 0.5), ("RIGHT", 0.75)):
        label(draw, (w * fraction, h * 0.46), text, 96)
    label(draw, (w * 0.04, h * 0.46), "BACK", 72)
    label(draw, (w * 0.96, h * 0.46), "BACK", 72)
    label(draw, (w / 2, h * 0.12), "UP", 72)
    label(draw, (w / 2, h * 0.88), "DOWN", 72)
    label(draw, (w / 2, h * 0.62), "360 still, 2:1", 48, (220, 220, 220))
    image.save(path)


def panorama(path, degrees=240):
    w, h = 4096, 1024
    image = sky_and_ground(w, h, int(h * 0.55))
    draw = ImageDraw.Draw(image)
    # A post every 30 degrees, numbered by its angle from the middle, so the cylinder's span shows.
    posts = int(degrees / 30)
    for i in range(posts + 1):
        angle = -degrees / 2 + 30 * i
        x = int(w * (0.5 + angle / degrees))
        x = min(max(x, 24), w - 24)
        draw.rectangle([(x - 8, h * 0.3), (x + 8, h * 0.72)], fill=(240, 200, 80))
        label(draw, (x, h * 0.24), f"{angle:+.0f}°", 52)
    label(draw, (w / 2, h * 0.85), f"Panorama, 4:1, drawn as {degrees}° wide", 56, (230, 230, 230))
    image.save(path, quality=90)


def flat(path, size, text):
    w, h = size
    image = sky_and_ground(w, h, int(h * 0.6))
    draw = ImageDraw.Draw(image)
    draw.ellipse([(w * 0.35, h * 0.12), (w * 0.65, h * 0.12 + w * 0.3)], fill=(250, 190, 60))
    label(draw, (w / 2, h * 0.8), text, 64)
    label(draw, (w / 2, h * 0.92), "This way up", 40, (220, 220, 220))
    image.save(path, quality=90)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    still_360(os.path.join(out, "fixture-360-still.png"))
    panorama(os.path.join(out, "fixture-panorama.jpg"))
    flat(os.path.join(out, "fixture-flat.jpg"), (1600, 1200), "Flat photo, 4:3")
    flat(os.path.join(out, "fixture-tall.jpg"), (1200, 1600), "Portrait photo, 3:4")
    for name in sorted(os.listdir(out)):
        if name.startswith("fixture-"):
            print(os.path.join(out, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
