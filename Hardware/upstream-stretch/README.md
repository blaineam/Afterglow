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

## Not done yet

- **The door.** It needs the same +7 / +12 stretch, which these scripts' method handles, plus two
  things they do not: a phone pocket enlarged from 68.96 × 142.97 to about 76.4 × 159.9, and a
  camera cutout for the iPhone 18 Pro Max's island. **That island's dimensions are the open
  question** — upstream's cutouts cannot be read off the mesh reliably because the door is
  perforated for ventilation and the vent gaps confound the measurement. Either measure a phone,
  or cut the opening deliberately oversized: the rear camera drives passthrough, hand tracking and
  QR scanning, so too large costs a little phone support while too small stops the app working.
- **The TPU corner locators**, which are sized per phone and need redoing for the new corners.
- **Fit between parts cannot be checked here.** The shell is modelled back-face-down and the
  carriage face-side-down, in different frames, and the download carries no assembly, so there is
  no transform to test them against each other. The argument that they still fit rests on their
  being cut on identical planes by identical amounts, not on a measurement.
- The band arms and focus wheel are untouched, and should not need changing.
