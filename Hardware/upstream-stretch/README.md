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

Every part is cut on the **same planes in its own coordinates** (y = ±55, x = ±26) and gains the
**same amounts** (6 mm each side along, 3.5 mm each side across), so a pair of mating features moves
together. Not quite the same thing as cutting them on the same planes in the assembly, as it turns
out — the print-ready STLs are each re-centred for the plate, and the door's origin sits 0.600 mm
across from the shell's. It does not matter here, and
[The door against the shell](#the-door-against-the-shell) measures why. The cuts sit outboard of the
lens bores, so the lens spacing the app's viewer profile depends on is untouched.

| | Before | After | Phone needs |
|---|---|---|---|
| Shell outer | 102.70 × 162.16 × 121.98 | 109.70 × 174.16 × 121.98 | — |
| **Phone bay** | **73.00 × 154.18** | **80.00 × 166.18** | **78.0 × 163.4** |
| Lens carriage | 72.50 × 153.58 × 30.25 | 79.50 × 165.58 × 30.25 | — |
| Door outer | 89.49 × 159.18 × 6.50 | 96.49 × 171.18 × 6.50 | — |
| TPU locators | ×4, 14.57 / 15.87 × 22.26 × 7.65 | **×2**, 18.07 / 19.37 × 22.26 × 7.65 | — |

That leaves 2.00 mm of clearance across and 2.78 mm along. For comparison the Pixel 9 Pro, the
largest phone upstream supports, has 1.00 and 1.38 mm.

## Checked

- **Topology is unchanged.** The shell is genus 208 before and after; the carriage is genus 2
  before and after, which is its two lens bores. No hole was created or closed.
- **The core is untouched.** All 1272 of the carriage's vertices inside the cut planes are still
  at exactly the same coordinates afterwards, so the bores cannot have moved.
- Every part renders with `Status: NoError`.

Measured off the rendered meshes, not computed:

- **Every part is one part.** Bambu Studio's own `--info` reports `manifold = yes` and
  `number_of_parts = 1` for the door and both locators. That check is worth running every time, and
  it has earned its keep twice. It caught the loose 267.78 mm³ island at the camera end, which
  OpenSCAD had reported as `Status: NoError`, genus 642, manifold — all true, and all compatible
  with the part being in two pieces. Then it caught two inside-out slivers, 0.36 and 0.03 mm³,
  where the camera-end fill stopped 0.31 and 0.11 mm short of faces at −42.311 and 40.605 instead
  of going past them.
  OpenSCAD's own export also leaves zero-area sliver facets at the cut planes (1256 of them in the
  door, 4 in a locator); the slicer discards them and so should any check, since upstream's files
  have the same class of artifact.
- **The door comes out 96.49 × 171.18 × 6.50**, and **genus 641**. That number matters: the plate
  carries a grid of 2 mm perforations, and an early attempt to fill the plate back in across the
  whole phone footprint closed almost all of them (genus 677 → 2). The fill is now two bounded
  pieces and costs about 36 of them.
- **The fill stays inside the door's outline.** A plain rectangle does not: measured against the
  stretched outline, a fill reaching 41.00 stands **9.40 mm proud at y 85**, squaring off the
  door's rounded camera-end corner. Both fills are clipped to that outline, which fits two straight
  sides at −42.90 and 41.20 closing on a **13.58 mm corner radius** at y 85.59 — good to 0.02 mm
  at every y from 75 to 85. The door's silhouette now matches the unmodified one at every y.
- **The camera end is continuous.** At mid-plate height the rim runs unbroken from y 79.5 to the
  door's end, with the opening closing at the phone's end less the 2.59 mm rim.
- **The MagSafe groove measures Ø43.99 … Ø58.00, 7.004 mm wide and 0.8 deep**, centred on
  (−0.86, 0.00) in the door's frame, which is the phone's centre to within 0.01 mm. 5774 vertices
  of the island inside it sit on the build plate, which is the point of making it a groove.
- **The locators stretch exactly as predicted**, and both are genus 0. Against the door's pockets
  they leave **0.231 / 0.235 mm across and 0.228 / 0.228 mm along** — measured on all four faces of
  both pockets, and upstream's own press fit, which the from-scratch version had no relationship to
  at all.
- **The collar clears both the phone and the bay**: 0.350 mm and 0.228 mm, with not one of 20169
  door surface points above the plate inside the shell.

## The door against the shell

Nothing above said whether the stretched door still drops into the stretched shell. It does, with
upstream's own clearances to the third decimal place.

The two can be compared at all because the STEP download is **one assembly**: `Viewer shell.step`
and `Door - iPhone 15 Pro.step` are modelled in a shared frame, and a boolean intersection of the
two solids is exactly **0 mm³**. The print-ready STLs are that same geometry re-centred for the
build plate, so each carries a fixed offset into that frame:

| | into the assembly frame |
|---|---|
| `Viewer shell (back face down).stl` | + (0.250, 0, −0.500) |
| `Door - iPhone 15 Pro (PETG, outer face down).stl` | + (0.850, 0, −2.500) |
| `TPU locator - … corner.stl` | + (0.850, 0, −2.500) |

Those are measured, not guessed. The shell's comes from its fourteen largest flat horizontal faces,
which land on the STEP's at exactly +0.500 in Z with areas agreeing to 0.3 mm², and from the
77.200 mm inner wall, which lands at +0.250 in X. The door's comes from the locators, whose STL
bounding boxes land on the STEP's locator solids to 0.003 mm under + (0.850, 0, −2.500).

**So the door's print frame is 0.600 mm across from the shell's.** Both are cut at x = ±26 in their
own coordinates, which puts the door's cut planes at +26.850 and −25.150 in the assembly and the
shell's at +26.250 and −25.750: two 0.600 mm bands where one part's material has slid 3.5 mm and
the other's has not. A mating feature with an edge inside one of those bands would be thrown 3.5 mm
out. None is — every door-to-shell contact sits between 38 and 47 across, well outboard of both
planes — and in Y the two frames agree exactly, so y = ±55 genuinely is shared. Worth knowing before
anyone cuts a part on a different plane.

Measured by cross-sectioning both meshes in the assembly frame at twelve heights from z = −0.45 to
z = 3.90 and comparing the outlines against each other:

| | upstream door, upstream shell | new door, stretched shell |
|---|---|---|
| outline crossings, all twelve heights | **0** | **0** |
| gap, hinge side | 0.300 mm | 0.300 mm |
| gap, latch side | 0.147 mm (0.156 at z = 0.5) | 0.147 mm (0.156 at z = 0.5) |
| tightest spot | 38.747 across | 42.247 across |

The clearances are identical, and the tightest spot has moved by exactly the 3.500 mm the insert
adds. That is the case for cut-and-bridge in one line: the fit is not re-derived, it is carried.

Two things about that fit are worth knowing before printing:

- **The seat is a flange.** The door's outline is full size below z = −0.500 and the shell has no
  material below it, so 2.00 mm of door stands proud of the shell's back face and the flange's top
  lands flush on it. The strip filled back into the plate (z −2.500 … −0.600) and the MagSafe
  groove (−2.500 … −1.700) are both inside that 2.00 mm, so neither can foul the shell however
  deep the groove is taken.
- **The locators clear the shell completely.** Not one of their 184–224 vertices is inside it, in
  any of the four corners.

How it was measured: read both STEP files with FreeCAD to establish the assembly frame, then work on
the meshes, because the meshes are what gets printed and the STEP is a different revision (its
locators are a sliding fit in the pockets where the printed ones are a press fit). Cross-sections
come from the triangle soup directly; the clearance is a nearest-neighbour query between the two
outlines sampled at 0.05 mm, and the crossing count is an orientation test on every door-segment /
shell-segment pair. Running the whole thing on upstream's own door and shell first is what makes the
numbers mean anything — without that control, 0.147 mm would look alarming rather than intentional.

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
openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -D 'part="usb-top"' -o locator-usb-top.stl locators.scad
```

`part` is `usb-top` or `usb-bottom`. There is no camera-end locator any more; `door.scad` carries a
collar instead.

## The door, the camera opening and MagSafe

`door.scad` stretches the iPhone 15 Pro door the same way, then does four things the method alone
cannot. It clears everything standing above the plate inside the phone's footprint, because the
upstream rim is sized for a 70.6 × 146.6 phone and would hold this one out rather than in. It cuts
the camera opening to clear the camera plateau, and fills the plate back in around it so a
**2.59 mm rim survives all the way round the camera end**. It stands a retaining collar up outside
the phone at that end. And it sinks a groove for a MagSafe ring.

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
| **Camera plateau** | inset **3.79** from the phone's outline | inset **3.93**, reaching **48.87** | — |
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

**Twice, and the second one cost more than the first.**

The plateau was first recorded as running **0.8 … 75.8 across**, which forced an opening 77.00 mm
wide on a 77.98 mm phone — the full width, with no rim at the camera end at all. The part printed
that way. 0.8 … 75.8 is the **antenna keepout**, a hatched region on the same sheet: "do not
obstruct this area with metal or other conductive material (full product volume including
sidewalls)". It runs the full width and a little past it, which is exactly why it looked like a
full-width plateau. A PETG door is not conductive, so it may cover that zone freely.

The second reading got the across figures right — 3.79/3.84/3.89 and 74.09/74.15/74.20, the plateau
wall and its chamfer, symmetric to 0.01 mm — and then **wrote them down as a rectangle**, `3.79 …
74.20 across by 0 … 48.87 along`, with the opening modelled as a rounded rectangle to match. Two
things follow from that, and both are wrong:

- it puts the plateau hard against the phone's camera end, at along 0. Sampling the drawing's paths
  across the band shows the near edge at **along 3.93**, in the same family of concentric lines as
  the 3.79/3.84/3.89 down the sides. The plateau is inset from the camera end exactly as it is from
  the sides.
- a rectangle cannot follow the phone's corner. The phone narrows from 77.98 to nothing over the
  last 15 mm, so a rectangle 70.40 wide keeps cutting at full width long after the phone has curved
  away — straight through the end of the door's plate, which is only about 66.6 mm wide there.

The result was a door severed at the camera end, with a **267.78 mm³ island** left attached to
nothing above the opening — Bambu Studio reported `number_of_parts = 2`.

**The plateau is the phone's own outline, brought in about 3.8 mm, closed off at along 48.87.** So
the opening is cut the same way: `phone_plan` shrunk by `rim_w`. It leaves the same rim everywhere
instead of a rim on the sides and nothing at the end, and the door comes out in one piece.

A third error went with the first. The opening was laid out in the door's own centred coordinates,
but the door is asymmetric — hinge knuckles down one long side, latch tabs down the other — so its
outline is offset from the bay it covers. Read off the door's own locator pockets, which are
symmetric about the phone, the phone's centre sits at **−0.855 across** in the door's frame. Every
phone-referenced feature was skewed by that much; `phone_cx` now carries it.

### What cannot be reproduced

The iPhone 15 Pro's camera island is a corner square, and upstream's opening for it is 48.48 ×
52.47, offset to one side, leaving about 22 mm of plate on the other. This door's opening has to
clear a plateau that is inset only 3.79 mm, so the rim it leaves is **2.59 mm wide, all the way
round the camera end**. That is enough to hold the phone, and it is continuous, but it is not 22 mm
and nothing will make it so.

What genuinely cannot be reproduced is **the two camera-end TPU locators**. Two separate things
rule them out:

- there is no room. Measured on the stretched shell in the door's own frame, the bay runs
  **−40.80 … 39.15 across** for its whole straight length, against a phone at −39.845 … 38.135 —
  about **1.0 mm a side**. Upstream's locator is 15.87 mm wide.
- there is nothing to hold them. The inboard half of each camera-end pocket lies under the plateau,
  which has to be cut through.

So the door grows a rigid collar there instead, which is what fits in 1 mm. The two USB-end
locators are untouched and still press into their pockets by upstream's own **0.231 … 0.235 mm a
side**, measured on all four faces of both pockets.

### Holding the phone at the camera end

The door grows a **collar**: a lip standing on the filled plate, just outside the phone's outline,
from `collar_y0` round the camera end. It is rigid PETG and part of the door, not a separate piece,
because what fits in the space is a known clearance rather than something compressible.

Every number in it is the bay's, measured on the stretched shell in the door's own frame rather
than taken from the nominal 80.00 × 166.18:

| | measured | |
|---|---|---|
| bay, across, whole straight length | −40.80 … 39.15 | the phone sits at −39.845 … 38.135 |
| room outboard of the phone | 0.955 mm left, **1.015 mm right** | |
| bay's camera-end wall | y **83.05** | the phone's end is y 81.715 |
| room beyond the phone's end | **1.335 mm** | the binding one |

So the collar is `collar_gap` 0.35 plus `collar_w` 0.80, and it starts at y 74, where the phone's
corner has curved far enough in to leave 2.2 mm. Measured on the rendered meshes: **0.350 mm to the
phone** (min and median over the corner profile) and **0.228 mm to the bay wall**, at every height
from z 2.10 to 4.45, with no crossings and not one of 20169 door surface points above the plate
inside the shell.

**What it buys:** the phone could travel 1.335 mm toward the camera end before the shell stopped
it. Now it travels 0.350.

One earlier version of this collar was 0.40 + 0.90 and started at y 60, sized off a reading of
1.87 mm of room taken at y 70 — which turns out to be one of two local pockets in the bay wall,
not the wall. It stood 0.28 mm inside the shell for 9 mm of its length. A spot reading off a
contoured part is worth what it costs.


### MagSafe

The groove is **Ø58.00 outside (57.50 plus 0.5 clearance), Ø44.00 inside, 0.8 mm deep, in the outer
face**, centred on the magnet array — which is the dead centre of the phone's back to within five
microns. Measured off the mesh it comes out Ø43.99 … Ø58.00, 7.004 mm wide. Any ring with an inside
diameter of 44 or more and an outside diameter of 58 or less drops in and is located by the outer
wall; `magsafe_id` is the one number to change if yours is narrower. Apple's drawing gives the array
as a single Ø57.50 circle with no inner diameter, so 44.00 is a choice, not a measurement.

It is a groove rather than a hole on purpose. The plate is 1.9 mm thick there and Apple's note 8
allows a case up to **2.1 mm on the back for full functionality**, so MagSafe already works through
the door; cutting through would only throw away plate that is holding the phone. The groove is
there to locate and seat a ring, not to let the magnets reach.

It is a groove rather than a full circular recess because of how the door prints — see
[Printing the door](#printing-the-door).

Keep magnets away from the **compass at 49.79 across, 157.45 along** — the drawing marks it "do not
obstruct with magnetic or permeable material".

## The locators

`locators.scad` makes the TPU corner pieces that take up the play between the phone and the bay.
Upstream ships four. **This makes two, both at the USB end** — see *What cannot be reproduced* for
why the camera-end pair are gone and what replaced them.

**They are a remake, because the first version did not fit.** It built them from scratch out of
bay-minus-phone arithmetic: a plain corner block, square inner corner, 17.60 × 19.99. Nothing in it
referred to the door's pockets, which are real features of the plate about 14.57 × 22.26 in each
corner — so the parts would not go in at all.

The remake does not model a locator. It takes upstream's own, which already fits the pocket, and

1. stretches it on exactly the same planes and by the same amounts as everything else, so the part
   that meets the pocket travels with the pocket;
2. cuts the phone out of it, leaving an inner face that is the phone's own corner — carried as the
   profile Apple draws rather than as a radius, because that corner is a continuous-curvature curve
   that no single radius matches.

### `squeeze` depends on the filament

`squeeze` is the one free number: the inner face is held that far inside the phone's outline, so the
locator is compressed when the phone goes in instead of letting it rattle. **The right value depends
on what the part is made of**, and the default here is the stiff one:

| filament | AMS? | `squeeze` |
|---|---|---|
| Bambu **TPU for AMS**, Shore **68D** | yes | **0.15** |
| ordinary TPU **95A** | no, external spool only | 0.60 |

68D is a semi-rigid engineering material, not a bumper. Asking it to give up 0.6 mm would either
refuse to go in or push the phone around; 0.15 mm is a close fit with a little give, which is what
68D can actually do. 0.60 is upstream's figure in spirit — their iPhone 15 Pro locator stands
1.81 mm proud of the phone corner into a 1.20 mm gap, which is 0.61 mm of the same thing, in 95A.

## Printing the door

**Outer face down, the way upstream prints theirs, and the STL already sits that way** — put it on
the plate without rotating it. That is measured, not inherited: the downward-facing flat area above
the plate is **1080 mm² that way up and 7237 mm² the other**, because flipping it puts the whole
inside of the plate — the land the phone rests on — in the air. Face down there is one bridge; face
up there are five, the largest 5904 mm² at Z 4.60.

**That orientation is what turned the MagSafe recess into a groove.** Anything sunk into the outer
face is a pocket that opens downward, so the plate above it has to bridge. A full Ø58 circular
recess left **2090 mm² of ceiling spanning 58 mm** with nothing beneath it, across a region carrying
the 2 mm perforation grid — so the bridge lines break at every hole and have nothing to anchor to.
The groove leaves everything inside Ø44 sitting on the plate from the first layer, and the longest
bridge in the part is now **7.004 mm**, anchored both sides. Changing `magsafe_id` changes that span
directly, so a narrower groove for a narrower ring prints better, not worse.

It is the only overhang worth a thought. The remaining 498 mm² of sloped underside is upstream's
own, unchanged, and prints as theirs does; the camera opening, the locator pockets and the
perforations all go straight through, so nothing needs support. The collar rises straight off the
plate, so it adds none.

Ask the slicer what it thinks before you print, not after:

```sh
/Applications/BambuStudio.app/Contents/MacOS/BambuStudio --info door.stl
```

`manifold = yes` and `number_of_parts = 1` are the two lines that matter. The second one has caught
two separate faults here that nothing in OpenSCAD's own report would have told you about.

## Printing the locators

**Print them in their own job and push them in. Do not glue them.**

Whether you can co-print them with the door now depends on which TPU you have:

- **Ordinary TPU 95A cannot go through the AMS at all.** Generic TPU, TPE and TPU 95A are listed
  incompatible with the AMS, AMS Lite and AMS 2 Pro, and the AMS errors on TPU 95A HF. It has to
  run off the external spool holder, which rules out automatic tool changes.
- **TPU for AMS (68D) can**, so a co-print is mechanically possible — but the geometry still
  interleaves. In upstream's own 3MF the plate occupies Z 0.00 … 6.50 and the locators Z 0.60 …
  8.25: about 5.9 mm of shared height, roughly 30 layers at 0.2 mm with two tool changes each.
  That is ~60 purges, on the order of 15–20 g of waste, and a wipe tower that has to survive 30
  layers of alternating TPU. The tower is how these prints usually fail.

A press fit needs none of it, and with only two locators left the second job is a few minutes.

## Not done yet

- **The door against the shell has now been checked**, collar included — see the section above.
  What has not is the **lens carriage** against the stretched shell, and the focus wheel against
  the carriage. The
  assembly frame and the method are both in hand now, so those are the same job again with
  different files.
- One thing the STEP settled that the meshes implied wrongly: the door and a locator intersect in
  **exactly zero** volume there, so in that revision they are a slip fit in the plate and the
  squeeze is against the phone and the bay, not against the pocket. The printed meshes do carry
  about 0.23 mm a side, and the meshes are what gets printed.
- **These scripts still work from the meshes, deliberately.** A shell printed from `shell.scad` is
  the one this door has to match, so the stretch stays exactly as it was and only the
  phone-facing features were changed. Moving the pipeline onto the STEP solids would be better
  CAD and would not fit a shell already on the shelf.
- The band arms and focus wheel are untouched, and should not need changing.
- **Nothing here has been printed.** Every number is measured off the meshes; none is measured off
  a part in hand.
