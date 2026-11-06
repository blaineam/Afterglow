# Publishing the iPhone 18 Pro Max viewer on MakerWorld

Two viewers live in this folder, and they go up differently:

- **The stretched upstream viewer** ([`upstream-stretch/`](upstream-stretch/)): brenpoly's
  [Mobile VR viewer for modern smartphones](https://makerworld.com/en/models/3511377-mobile-vr-viewer-for-modern-smartphones)
  cut, moved and bridged to take the iPhone 18 Pro Max, with a door of its own design. This is
  the one people ask for, and it is a **derivative of a CC BY-NC-SA model**, so it is published
  as a **Remix** of model 3511377 under **CC BY-NC-SA 4.0**, crediting brenpoly. Its STLs are
  generated, never committed (the licence is why).
- **The parametric viewer** ([`viewer.scad`](viewer.scad), `body.stl`, `plate.stl`, `door.stl`):
  this repository's own design, Apache-2.0, an original model under any licence you like. Simpler,
  and not what the app was tuned around.

The rest of this file is the remix listing.

## Files to upload

Generate them from the scripts, pointing `SRCDIR` at the unzipped upstream download (the three
upstream STLs are the inputs; nothing of them is in this repository):

```bash
cd Hardware/upstream-stretch && for part in shell carriage door; do openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o "Afterglow viewer - iPhone 18 Pro Max - $part.stl" $part.scad; done
```

| File | Part | Material | Orientation (as exported) |
|---|---|---|---|
| `… - shell.stl` | Viewer shell, 7 mm wider and 12 mm longer than upstream's | PETG | Back face down |
| `… - carriage.stl` | Lens carriage, stretched to match | PETG | Face side down |
| `… - door.stl` | Door: stretched frame, new plate with the camera-island opening, MagSafe groove and four integral anchors | PETG | Outer face down |

Plus, from upstream unchanged: the focus wheel and the knit band arm (link to them rather than
re-uploading). Check each STL with the slicer before uploading (`manifold = yes`,
`number_of_parts = 1`):

```bash
/Applications/BambuStudio.app/Contents/MacOS/BambuStudio --info "Afterglow viewer - iPhone 18 Pro Max - door.stl"
```

Images: a render of the three parts and, for the listing to be accepted, at least one photo of
the printed viewer with the phone in it.

## Listing

**Model type**: Remix of [Mobile VR viewer for modern smartphones](https://makerworld.com/en/models/3511377-mobile-vr-viewer-for-modern-smartphones) by brenpoly.

**Licence**: CC BY-NC-SA 4.0 (the same as the original; it cannot be anything else).

**Title**: Mobile VR viewer for the iPhone 18 Pro Max (remix, with a MagSafe door)

**Summary**: brenpoly's Mobile VR viewer stretched to fit the iPhone 18 Pro Max, with a door
designed for this phone: camera-island opening, MagSafe groove, integral anchors, no TPU parts.
Made for the open-source Afterglow app (6DoF, passthrough, hand tracking, WebXR).

**Description**:

The original viewer's phone bay is 73.00 × 154.18 mm; the iPhone 18 Pro Max is 78.0 × 163.4 mm.
This remix makes the shell and the lens carriage bigger without scaling them: each is cut on the
same planes, the outer pieces slide outward and the gap is bridged, so the lenses stay exactly
where the original put them (the app's distortion profile depends on that) and every feature keeps
its true size. The bay becomes 80.00 × 166.18 mm.

The door is new. It keeps the stretched frame that mates with the shell (outline, flange, hinge
knuckles, latch tabs) and replaces the plate: a hex dot field, an opening shaped to this phone's
camera island (70.12 × 38.23 mm with a 1.2 mm margin), a MagSafe groove for an adhesive metal ring
(Ø58 / Ø44, 0.8 mm deep; the plate stays within Apple's 2.1 mm MagSafe limit), and four anchors
that stand on the plate at the phone's corners. One printed part per phone; there are no TPU
locators.

Print all three in PETG at 0.2 mm or finer, no supports, in the orientations the files come in:
shell back face down, carriage face side down, door outer face down (the MagSafe groove is a groove
rather than a recess so the door needs no support that way up; its longest bridge is 7 mm). The
focus wheel and the knit band arm are the original's, unchanged: print them from the original
model.

Lenses, strap and foam are the original's too: two Cardboard v2 lenses (25 mm, about 34 mm focal
length), a 25 mm strap, face foam.

The app: Afterglow (https://github.com/blaineam/Afterglow), free and open source, is phone VR for
this viewer on the iPhone: 6DoF head tracking, camera passthrough through the ultra-wide lens, hand
tracking on the Neural Engine, spatial photos and videos, panoramas, your own 360 photos as the
surroundings, and a WebXR browser that gives pages your hands. The measurements behind this remix
are written up in the repository under `Hardware/`.

Credit: Mobile VR viewer for modern smartphones by brenpoly, CC BY-NC-SA. This remix carries the
same licence: credit, non-commercial, share alike.

**Tags**: VR, phone VR, iPhone 18 Pro Max, Google Cardboard, headset, viewer, MagSafe, remix,
WebXR, Afterglow

**Category**: Gadgets → Phone accessories (or Toys & Games → VR, whichever MakerWorld offers)

## Steps on the site

1. Sign in, open **Upload**, choose **Remix** and give the original model's link (3511377).
2. Add the three STLs and the images; name the parts as the files are named.
3. Paste the title, summary and description; add the tags and the category.
4. Set the licence to CC BY-NC-SA 4.0 (MakerWorld may set it from the original automatically).
5. Preview, then **Publish**.
