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
| TPU locators ×4 | 14.57 / 15.87 × 22.26 × 7.65 | 18.07 / 19.37 × 22.26 × 7.65 | — |

That leaves 2.00 mm of clearance across and 2.78 mm along. For comparison the Pixel 9 Pro, the
largest phone upstream supports, has 1.00 and 1.38 mm.

## Checked

- **Topology is unchanged.** The shell is genus 208 before and after; the carriage is genus 2
  before and after, which is its two lens bores. No hole was created or closed.
- **The core is untouched.** All 1272 of the carriage's vertices inside the cut planes are still
  at exactly the same coordinates afterwards, so the bores cannot have moved.
- Every part renders with `Status: NoError`.

Measured off the rendered meshes, not computed:

- **The door comes out 96.50 × 171.18 × 6.50**, and **genus 642**. That number matters: the plate
  carries a grid of 2 mm perforations, and an earlier attempt to fill the plate back in across the
  whole phone footprint closed almost all of them (genus 677 → 2). The fill is now one strip, which
  costs about 35 of them.
- **The camera opening's edges land where they are meant to**: vertical runs at −37.26 and 35.55
  across, over roughly 18 mm each. Before the strip fill they were at −37.26 and **40.37** — that
  is, cutting a narrower opening had not narrowed the hole at all, because upstream's own opening
  was still there and the two unioned. The pockets still open out to 40.37 over the 21.8 mm the
  locators pass through, which they have to.
- **The MagSafe recess measures 58.00 × 58.00 centred on (−0.86, 0.00)** in the door's frame, which
  is the phone's centre to within 0.01 mm.
- **The locators stretch exactly as predicted.** camera-top comes out X 21.24 … 40.61, Y 62.69 …
  84.95, Z 0.60 … 8.25 against a prediction of 21.24 … 40.61 and 62.69 … 84.95 with Z untouched,
  and all four are genus 0. Against the door's pockets that leaves about 0.23 mm of interference a
  side — upstream's own press fit, which the from-scratch version had no relationship to at all.

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

## The door, the camera opening and MagSafe

`door.scad` stretches the iPhone 15 Pro door the same way, then does three things the method alone
cannot. It clears everything standing above the plate inside the phone's footprint, because the
upstream rim is sized for a 70.6 × 146.6 phone and would hold this one out rather than in. It cuts
the camera opening to clear the camera plateau. And it sinks a recess for a MagSafe ring.

All of it comes from **Apple's own published geometry**. The Accessory Design Guidelines point at a
per-device drawing library, and the iPhone 18 Pro Max is published there as a dimensioned mechanical
drawing
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
| **Camera plateau** | **3.79 … 74.20** | **0 … 48.87** | — |
| **MagSafe magnet array** | 38.99 (centre) | 81.72 (centre) | **57.50** |

### How those were measured

Not by eye. The drawing is vector, so it is converted with `pdftocairo -svg`, each path's own
`matrix(...)` is applied — pdftocairo gives every path its own local origin, so skipping that step
produces nonsense — and the scale is calibrated on the lens circles, whose centres Apple dimensions
exactly. One scale, 2.7652 SVG units per mm, fits all of sheets 1 and 4; the phone's corner arcs
then land on 0.00 … 77.97 across and 0.00 … 163.44 along against a stated 77.98 × 163.43, so the
calibration is good to about 0.01 mm. The plateau's edges are read off its straight runs, which
appear as three concentric vertical lines a side at 3.79/3.84/3.89 and 74.09/74.15/74.20 — the
plateau wall and its chamfer, symmetric to 0.01 mm.

### The correction this made

The plateau was previously recorded as running **0.8 … 75.8 across**, and that forced an opening
**77.00 mm wide on a 77.98 mm phone** — the full width, with no rim left at the camera end at all.
The part printed that way, and it is wrong.

0.8 … 75.8 is the **antenna keepout**, a different region on the same sheet: "do not obstruct this
area with metal or other conductive material (full product volume including sidewalls)". It runs
the full width and a little past it, which is exactly why it looked like a full-width plateau. A
PETG door is not conductive, so it may cover that zone freely. Only the raised plateau has to be
cleared, and that measures **3.79 … 74.20 across — 70.40 wide, inset 3.79 mm from each side wall**.

The opening is now **72.81 × 51.37**, leaving **2.59 mm of rim over the phone on each side**.

A second error went with it. The opening was laid out in the door's own centred coordinates, but
the door is asymmetric — hinge knuckles down one long side, latch tabs down the other — so its
outline is offset from the bay it covers. Read off the door's own locator pockets, which are
symmetric about the phone, the phone's centre sits at **−0.855 across** in the door's frame. Every
phone-referenced feature was skewed by that much; `phone_cx` now carries it.

### What cannot be reproduced

The iPhone 15 Pro's camera island is a corner square, and upstream's opening for it is 48.48 ×
52.47, offset to one side, leaving about 22 mm of plate on the other — so that door holds the phone
at the camera end. **This door cannot.** The 18 Pro Max's plateau is 70.40 of 77.98 mm, a
near-full-width shelf, and no opening that clears it leaves more than about 2.6 mm a side. The
phone changed; a door for it has to hold the phone somewhere other than across the camera end.

### MagSafe

The recess is **Ø58.00 (57.50 plus 0.5 clearance), 0.8 mm deep, in the outer face**, centred on the
magnet array — which is the dead centre of the phone's back to within five microns.

It is a recess rather than a hole on purpose. The plate is 1.9 mm thick there and Apple's note 8
allows a case up to **2.1 mm on the back for full functionality**, so MagSafe already works through
the door; cutting through would only throw away plate that is holding the phone. The recess is
there to locate and seat a ring, not to let the magnets reach.

Keep magnets away from the **compass at 49.79 across, 157.45 along** — the drawing marks it "do not
obstruct with magnetic or permeable material".

## The locators

`locators.scad` makes the four TPU corner pieces, which are what actually take up the play between
the phone and the bay — there is no pocket in the door to do it.

**They are a remake, because the first version did not fit.** It built them from scratch out of
bay-minus-phone arithmetic: a plain corner block, square inner corner, 17.60 × 19.99. Nothing in it
referred to the door's pockets, which are real features of the plate about 14.57 × 22.26 in each
corner — so the parts would not go in at all.

The remake does not model a locator. It takes upstream's own locator, which already fits the
pocket, and

1. stretches it on exactly the same planes and by the same amounts as everything else, so the part
   that meets the pocket travels with the pocket;
2. cuts the phone out of it, leaving an inner face that is the phone's own corner — carried as the
   profile Apple draws rather than as a radius, because that corner is a continuous-curvature curve
   that no single radius matches.

Step 2 also absorbs the change in play with no arithmetic of its own. The phone grew 16.83 mm along
where the bay grew 12.00, closing the end gap from 7.58 mm to 2.75; cutting the real phone out of
the stretched locator leaves exactly what that gap has room for.

`squeeze` is the one free number: the inner face is held 0.60 mm inside the phone's outline, so the
locator is compressed when the phone goes in. Upstream's iPhone 15 Pro locator stands 1.81 mm proud
of the phone corner into a 1.20 mm gap, which is 0.61 mm of the same thing.

## Printing the locators

**Print them separately and push them in. Do not try to co-print them with the door, and do not
glue them.**

Upstream ships both options — four TPU locator STLs beside the plain door, and a
`Multi-material doors/` folder with the two as one 3MF — so co-printing is possible. It is still
the wrong trade here:

- **The AMS cannot feed ordinary TPU.** Generic TPU, TPE and TPU 95A are listed incompatible with
  the AMS, AMS Lite and AMS 2 Pro, and the AMS errors on TPU 95A HF. The only AMS-feedable flexible
  is Bambu's *TPU for AMS*, a **Shore 68D** formulation — far stiffer than 95A, on a part whose
  whole job is to be squeezed by 0.6 mm and damp the phone.
- **The geometry interleaves.** In upstream's own 3MF the plate occupies Z 0.00 … 6.50 and the
  locators Z 0.60 … 8.25 — about 5.9 mm of shared height, roughly 30 layers at 0.2 mm with two tool
  changes each. That is ~60 purges, on the order of 15–20 g of waste, and a wipe tower that has to
  survive 30 layers of alternating TPU. The tower is how these prints usually fail.

A press fit needs neither. If you do want it in one job, make the TPU its own Z band — a shallower
pocket cuts the interleave to ~8 layers, and a soft feature sitting entirely above the plate's top
face is a single filament change with no tower at all.

## Not done yet

- **Fit between parts has still not been checked**, but it now can be. The download's
  `STEP file for remixing/` folder carries the shell, door, lens carriage, focus wheel and band
  arms as solids, and they share one assembly frame: the shell spans Y ±81.09 around the door's
  ±79.59, and the carriage's Z sits inside the shell's. That is the transform this file once said
  did not exist. Reading the STEP also settled one thing the meshes implied wrongly — the door and
  a locator intersect in **exactly zero** volume, so they are a slip fit in the plate and the
  squeeze is against the phone and the bay, not against the pocket.
- **These scripts still work from the meshes, deliberately.** A shell printed from `shell.scad` is
  the one this door has to match, so the stretch stays exactly as it was and only the
  phone-facing features were changed. Moving the pipeline onto the STEP solids would be better
  CAD and would not fit a shell already on the shelf.
- The band arms and focus wheel are untouched, and should not need changing.
- **Nothing here has been printed.** Every number is measured off the meshes; none is measured off
  a part in hand.
