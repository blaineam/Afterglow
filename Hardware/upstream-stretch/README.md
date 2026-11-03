# Stretching brenpoly's viewer to fit an iPhone 18 Pro Max

These scripts take the published parts of
[Mobile VR viewer for modern smartphones](https://makerworld.com/en/models/3511377-mobile-vr-viewer-for-modern-smartphones)
and make them bigger, because that viewer's phone bay measures **73.00 × 154.18 mm** and the
iPhone 18 Pro Max is **78.0 × 163.4 mm**. See [../UPSTREAM-VIEWER.md](../UPSTREAM-VIEWER.md) for
how that was measured.

## Licence, before anything else

The upstream model is **CC BY-NC-SA**. Anything these scripts produce is a derivative, so it
carries the same terms: credit brenpoly, non-commercial only, and share alike. That is why the
generated STLs are **not** committed here — only the scripts, which are instructions for
reshaping a file you downloaded yourself. The rest of this repository is Apache-2.0; this folder
is the exception, and mixing the two in a published print would be a licence problem.

## What they do

The shell cannot be scaled: scaling moves the lenses apart and turns their bores into ellipses.
So each part is **cut, moved and bridged** — the outer pieces slide outward and the gap is filled
by extruding the cut face straight. Every feature keeps its true size; the contour gains a flat
band as wide as the insert.

Both parts are cut on the **same planes** (y = ±55, x = ±26) and gain the **same amounts**
(6 mm each side along, 3.5 mm each side across), so any pair of mating features moves together.
The cuts sit outboard of the lens bores, so the lens spacing the app's viewer profile depends on
is untouched.

| | Before | After | Phone needs |
|---|---|---|---|
| Shell outer | 102.70 × 162.16 × 121.98 | 109.70 × 174.16 × 121.98 | — |
| **Phone bay** | **73.00 × 154.18** | **80.00 × 166.18** | **78.0 × 163.4** |
| Lens carriage | 72.50 × 153.58 × 30.25 | 79.50 × 165.58 × 30.25 | — |
| Door outer | 89.49 × 159.18 × 6.50 | 96.49 × 171.18 × 6.50 | — |
| TPU locators ×4 | 15.87 × 22.26 × 7.65 | 17.60 × 19.99 × 7.60 | — |

That leaves 2.00 mm of clearance across and 2.78 mm along. For comparison the Pixel 9 Pro, the
largest phone upstream supports, has 1.00 and 1.38 mm.

## Checked

- **Topology is unchanged.** The shell is genus 208 before and after; the carriage is genus 2
  before and after, which is its two lens bores. No hole was created or closed.
- **The core is untouched.** All 1272 of the carriage's vertices inside the cut planes are still
  at exactly the same coordinates afterwards, so the bores cannot have moved.
- Both parts render with `Status: NoError`.

## Running them

```sh
openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o shell.stl shell.scad
```

```sh
openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o carriage.stl carriage.scad
```

```sh
openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o door.stl door.scad
```

```sh
openscad -D 'part="camera-top"' -o locator-camera-top.stl locators.scad
```

## The door, and the camera opening

`door.scad` stretches the iPhone 15 Pro door the same way, then does two things the method alone
cannot. It clears everything standing above the plate inside the phone's footprint, because the
upstream rim is sized for a 70.6 × 146.6 phone and would hold this one out rather than in. And it
cuts the camera opening to **Apple's own published geometry**.

Apple's Accessory Design Guidelines point at a per-device drawing library, and the iPhone 18 Pro
Max is published there as a dimensioned mechanical drawing
([developer.apple.com/accessories/dimensional-drawings/](https://developer.apple.com/accessories/dimensional-drawings/),
sheet dated 2026-09-09). It gives the body as **163.43 × 77.98 × 8.75**, every imaging feature's
centre and diameter, and the plateau standing **2.78 mm** proud of the back plate with the camera
glass **2.11 mm** above that again.

| Feature | Across | Along | Ø |
|---|---|---|---|
| Rear camera 1 | 14.37 | 14.37 | 16.58 |
| Rear camera 2 | 14.37 | 33.61 | 16.58 |
| Rear camera 3 | 32.49 | 23.99 | 16.58 |
| Flash | 64.16 | 13.82 | 6.90 |
| Rear mic | 64.16 | 23.99 | 1.15 |
| Rear sensor | 64.16 | 34.16 | 6.90 |

Measured off the same drawing, the plateau runs about 0.8–75.8 across and 0.5–46.7 along: within
a millimetre of the phone's long edges and half a millimetre of its end.

**This corrected a real error.** A first pass cut the opening "generously oversized" at 70.6 × 52
with a 6 mm end rim, on the reasoning that too large only costs support while too small breaks
tracking. Against Apple's figures that opening is too *small*: it would have rested on the plateau
by about 3 mm each side and lapped 5.5 mm over its end, and the door would not have closed flat.
The opening is now 77.00 × 56.77, clearing the plateau by 0.80 and 1.20 mm across and 8.77 and
1.80 mm along.

## The locators

`locators.scad` makes the four TPU corner pieces, which are what actually take up the play between
the phone and the bay — there is no pocket in the door to do it. They stand 0.60 mm proud of the
bay so they go in with a squeeze; upstream's iPhone 15 Pro locator stands 1.81 mm proud of the
phone corner into a 1.20 mm gap, which is 0.61 mm of the same thing.

## Not done yet

- **Fit between parts cannot be checked here.** The shell is modelled back-face-down and the
  carriage face-side-down, in different frames, and the download carries no assembly, so there is
  no transform to test them against each other. The argument that they still fit rests on their
  being cut on identical planes by identical amounts, not on a measurement.
- The band arms and focus wheel are untouched, and should not need changing.
- **Nothing here has been printed.** Every number is measured off the meshes; none is measured off
  a part in hand.
