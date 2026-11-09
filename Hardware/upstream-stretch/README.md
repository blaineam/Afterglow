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

## The parts

| script | makes | material |
|---|---|---|
| `shell.scad` | the viewer shell | PETG |
| `carriage.scad` | the lens carriage | PETG |
| `door.scad` | the door, **complete** — plate, anchors and all | PETG |
| `phone.scad` | not a part: the phone's outline, shared by the others | — |

**One printed part per phone.** There are no TPU locators. `locators.scad` used to make four and
then two; it is gone, because the door now carries integral anchors (see below) and separate soft
parts turned out to be the wrong answer for this phone.

## How the shell and carriage are made bigger

They cannot be scaled: scaling moves the lenses apart and turns their bores into ellipses. So each
is **cut, moved and bridged** — the outer pieces slide outward and the gap is filled by extruding
the cut face straight. Every feature keeps its true size; the contour gains a flat band as wide as
the insert.

Every part is cut on the **same planes in its own coordinates** (y = ±55, x = ±26) and gains the
**same amounts** (6 mm each side along, 3.5 mm each side across), so a pair of mating features
moves together. Not quite the same thing as cutting them on the same planes in the assembly — the
print-ready STLs are each re-centred for the plate, and the door's origin sits 0.600 mm across from
the shell's. It does not matter here, and
[The door against the shell](#the-door-against-the-shell) measures why. The cuts sit outboard of
the lens bores, so the lens spacing the app's viewer profile depends on is untouched.

| | Before | After | Phone needs |
|---|---|---|---|
| Shell outer | 102.70 × 162.16 × 121.98 | 109.70 × 174.16 × 121.98 | — |
| **Phone bay** | **73.00 × 154.18** | **80.00 × 166.18** | **78.0 × 163.4** |
| Lens carriage | 72.50 × 153.58 × 30.25 | 79.50 × 165.58 × 30.25 | — |
| Door outer | 89.49 × 159.18 × 6.50 | 96.49 × 171.18 × 6.50 | — |

## How the door is made

**The door does not reuse upstream's plate.** It keeps the stretched frame — the outline, the
flange, the hinge knuckles and the latch tabs, which are what the shell mates with — fills the
plate solid, and cuts a new interior: a hex dot field, an opening shaped to this phone's camera
island, a MagSafe groove, and four anchors.

That is a deliberate change of approach, and it exists because keeping upstream's plate produced
two faults that could not be patched out:

- **the camera opening had a step in its lower edge.** Upstream's own opening, sized for an
  iPhone 15 Pro's corner-square island, is still in the stretched mesh — the method only ever moves
  material — so it unioned with the new one and the hole ended up as wide as whichever was wider.
- **the dot field came out as rows of dashes.** Cut-and-bridge extrudes whatever lies on a cut
  plane, and the dots lie on the cut planes.

Nothing of upstream's plate survives now, so neither can.

### The camera island

**It is the phone's outline that is inset, not the island.** Three readings of this drawing were
wrong before the fourth was right, and the first two each cost a printed part:

| reading | what it said | what it was |
|---|---|---|
| 1 | across 0.8 … 75.8 | the **antenna keepout** — hatched, "do not obstruct with metal or other conductive material", full width and past it. A PETG door may cover it freely. |
| 2 | a rectangle, across 3.79 … 74.20 by along **0 … 48.87** | right walls, wrong shape and wrong ends. A rectangle cannot follow a phone that narrows to nothing over its last 15 mm, and starting at along 0 put the island hard against the phone's end. It cut the door's camera end clean off. |
| 3 | the phone's outline inset 3.79 | the walls agree on the straight sides, so it looked right, and it is still wrong at the corners and at the end. |
| **4** | **a rounded rectangle, across 3.93 … 74.05 by along 4.87 … 43.10** | checked by plotting the drawing's own paths on a millimetre grid in the phone's coordinates and reading the island off it. |

So the island is **70.12 × 38.23**, centred across the phone, with a corner radius somewhere
between 12 and 15. `door.scad` uses **12**, because a smaller radius makes the opening cut
*further* into the corners — over-cutting costs a little rim, under-cutting leaves the door resting
on the island.

The opening is that rectangle plus a 1.2 mm margin all round: **72.81 × 40.63**, measured on the
mesh at 72.80 × 40.50. Reading 2 made it 72.81 × 51.37 — ten millimetres too long, four of them
off the end of the door.

| Feature | Across | Along | Ø |
|---|---|---|---|
| Rear camera 1 | 14.37 | 14.37 | 16.58 |
| Rear camera 2 | 14.37 | 33.61 | 16.58 |
| Rear camera 3 | 32.49 | 23.99 | 16.58 |
| Flash | 64.16 | 13.82 | 6.90 |
| Rear mic | 64.16 | 23.99 | 1.15 |
| Rear sensor | 64.16 | 34.16 | 6.90 |
| **Camera island** | **3.93 … 74.05** | **4.87 … 43.10** | — |
| **MagSafe magnet array** | 38.99 (centre) | 81.72 (centre) | **57.50** |
| Compass — keep magnets away | 49.79 | 157.45 | — |

### How to read Apple's drawing without getting it wrong

The sheets are vector, so `pdftocairo -svg` converts one to paths. pdftocairo gives **every path
its own** `matrix(...)`, so skipping the per-path transform produces nonsense. Calibrate on
features Apple dimensions exactly — the lens circles — and the scale comes out at 2.7652 SVG units
per mm; the phone's corner arcs then land on 0.00 … 77.97 across and 0.00 … 163.44 along against a
stated 77.98 × 163.43, good to about 0.01 mm.

**Then plot it and look at it.** Every wrong reading above came from inferring a shape out of
clusters of path coordinates. One `matplotlib` plot of the paths in phone coordinates with a 5 mm
grid settled in a minute what three rounds of arithmetic had got wrong, and it also shows at a
glance which lines belong to the island, which to the keepout, and which to the phone's own edge
chamfer — three families that all run parallel a few millimetres apart.

Beware too that a sheet holds several views side by side. Calibrate inside one view and stay there.

### MagSafe

An annular **groove** in the outer face: Ø58.00 outside (Apple's 57.50 plus 0.5 so a ring drops in),
Ø44.00 inside, 0.8 mm deep, in a solid band the dot field leaves clear for it. It takes an adhesive
metal ring.

A groove rather than a hole, because the plate is 1.9 mm thick there and Apple's note 8 allows a
case up to **2.1 mm on the back for full functionality** — MagSafe already works through it, and
cutting through would only throw away plate that is holding the phone.

A groove rather than a circular recess, because of how the door prints. See
[Printing the door](#printing-the-door).

### The anchors

Four ribs standing on the plate just outside the phone's outline, at the corners, from the plate up
to z 5.00. They are part of the door, printed in PETG with it.

Every size is the bay's, measured on the stretched shell in the door's own frame rather than taken
from the nominal 80.00 × 166.18:

| | measured |
|---|---|
| bay, across, whole straight length | −40.80 … 39.15, against a phone at −39.845 … 38.135 |
| room outboard of the phone | 0.955 mm left, **1.015 mm right** |
| bay's end wall | y **83.05**, against a phone end at 81.715 |
| room beyond the phone's end | **1.335 mm** |

So an anchor is 0.35 mm of clearance plus a 0.80 mm rib, and it starts at |y| = 74 where the
phone's own corner has curved in far enough to leave 2.2 mm. Measured on the rendered mesh:
**0.350 mm to the phone** at every one of 40 points round the four corners, **0.228 mm to the bay
wall**, and not one of 22536 door surface points above the plate inside the shell.

**Soft locators were tried twice and are the wrong answer here.** Upstream's TPU corner pieces are
15.87 mm wide; there is 1.0 mm of room. The half of the pocket that would hold one lies under the
camera island, which has to be cut through. And the only AMS-feedable flexible is Bambu's *TPU for
AMS*, a Shore **68D** formulation — a semi-rigid engineering material that will not give up the
0.6 mm a bumper needs. A rigid rib at a known clearance is what fits in 1 mm.

## Doors for other iPhones

[The door generator](https://wemiller.com/apps/afterglow/door/) builds this door for the LiDAR Pro iPhones from the
15 Pro on, or for a custom size, in the browser. It is a modified copy of brenpoly's Apache-2.0 generator, so it
contains none of the CC BY-NC-SA mesh: its frame is parametric. Against `door.scad`'s output for the 18 Pro Max, the
frame outside the bay differs by 0.34 % of its volume and the bounding box is identical.

**Below about 75.6 mm wide, a phone misses the screen shelves.** Measured on the stretched shell, in the assembly frame:

| | |
|---|---|
| bay, up to z 7.9 | ±40.00 across, ±83.09 along, corner radius 11.5 |
| shelves, z 8.4 to 10.3 | inner edge x 37.0 at \|y\| 68 to 72, y 80.5 at \|x\| 22 to 30 |
| carriage flange lands on the rim at | about z 10.4 |

Stretching moved the shelves out with the walls, so a Pro Max seats on them but a 71.9 mm iPhone 17 Pro passes straight
through with nothing to stop it short of the carriage. Its door has to hold the glass, so those doors get four rigid
clips 14 to 25 mm from each end, clear of Apple's button positions, each lapping the glass by 0.6 mm.

**Phones up to 165 mm long fit, not 166.** The bay is 166.18 mm long. Take away the door's 0.228 mm clearance to the
bay wall and the 0.35 mm gap to the phone at each end, and above about 163.4 mm there is no room left for the anchors'
0.8 mm end walls. Past that point the generator drops whatever the bay trims thinner than a wall, and the bay's own ends
locate the phone. On a clipped phone over about 164 mm, the clips would also run under the screen shelves, so they stop
0.5 mm short of y 68. At 166 mm there would be 0.09 mm a side, which no printer holds. The checker builds three 165 mm
phones: a Pro Max outline, the same size as a 12 mm-radius rectangle, and a clipped Pro outline.

**MagSafe is not always central.** From the drawings, centre of the magnets from the phone's centre, toward the USB end:
15 Pro 1.67, 16 Pro 0.37, 16 Pro Max 0.25, 17 Pro and 18 Pro 2.73, and 0 on the other Pro Max phones.

`scripts/check-door-generator.mjs` in the site repo tests every door against the shell's mesh, shut and at twelve
hinge angles with the phone in it. `Tools/test_door_generator.sh` runs it, as Soren's `door` suite. The printed 18 Pro Max
door passes the same hinge sweep, as a control.

## Printing the door

**Outer face down, the way upstream prints theirs, and the STL already sits that way** — put it on
the plate without rotating it. Measured on the mesh, the downward-facing flat area above the plate
is **1121 mm² that way up and about 7000 mm² the other**, because flipping it puts the whole inside
of the plate — the land the phone rests on — in the air.

That orientation is what makes the MagSafe groove a groove. Anything sunk into the outer face is a
pocket that opens downward, so the plate above it has to bridge, and a full Ø58 circular recess
left **2090 mm² of ceiling spanning 58 mm** with nothing beneath it. The groove leaves everything
inside Ø44 sitting on the plate from the first layer, and the longest bridge in the part is
**7.00 mm**, anchored both sides.

Nothing needs support: the opening, the dot field and the groove all go straight through or open
upward, and the anchors rise off the plate. Use a 0.2 mm layer or finer so the 0.8 mm groove is a
clean four layers. The anchors are a 0.80 mm wall 3.1 mm tall — two perimeters at a 0.4 nozzle.

Ask the slicer what it thinks before you print, not after:

```sh
/Applications/BambuStudio.app/Contents/MacOS/BambuStudio --info door.stl
```

`manifold = yes` and `number_of_parts = 1` are the two lines that matter. The part count has caught
three separate faults here that nothing in OpenSCAD's own report would have told you about: a loose
267.78 mm³ island at the camera end, and twice a pair of inside-out slivers where a fill block
stopped a fraction of a millimetre short of an existing face.

## Checked

- **Topology is unchanged** where it should be. The shell is genus 208 before and after; the
  carriage is genus 2 before and after, which is its two lens bores.
- **The core is untouched.** All 1272 of the carriage's vertices inside the cut planes are still at
  exactly the same coordinates afterwards, so the bores cannot have moved.
- Every part renders with `Status: NoError`, and Bambu Studio reports `manifold = yes` and
  `number_of_parts = 1`.

Measured off the rendered meshes, not computed:

- **The door comes out 96.49 × 171.18 × 6.50**, one part, 19 200 mm³.
- **The opening measures 72.80 wide by y 37.4 … 78.0**, against a design of 72.81 × 40.63.
- **Nothing stands proud of the door's outline.** The door's own body is a rounded rectangle at
  −42.90 … 41.20 across, ±85.59 along, corner radius 13.58 — a fit to **±0.10 mm** at every
  millimetre of both ends — and everything built here is clipped to it. An earlier fill that was
  not clipped stood **9.40 mm proud at y 85**, squaring off the rounded corner.
- **The anchors clear both the phone and the bay**: 0.350 mm and 0.228 mm, at all four corners.
- **The MagSafe groove measures Ø44.00 … Ø58.00, 0.8 deep**, centred on the phone's centre to
  within 0.01 mm.

## The door against the shell

The STEP download is **one assembly**: a boolean intersection of `Viewer shell.step` and
`Door - iPhone 15 Pro.step` is exactly **0 mm³** while their bounding boxes overlap. The
print-ready STLs are that same geometry re-centred for the build plate, so each carries a fixed
offset into that frame:

| | into the assembly frame |
|---|---|
| `Viewer shell (back face down).stl` | + (0.250, 0, −0.500) |
| `Door - iPhone 15 Pro (PETG, outer face down).stl` | + (0.850, 0, −2.500) |

Those are measured. The shell's comes from its fourteen largest flat horizontal faces, which land
on the STEP's at exactly +0.500 in Z with areas agreeing to 0.3 mm², and from the 77.200 mm inner
wall, which lands at +0.250 in X. The door's comes from upstream's locators, whose STL bounding
boxes land on the STEP's locator solids to 0.003 mm.

**So the door's print frame is 0.600 mm across from the shell's**, which puts the door's cut planes
at +26.850 and −25.150 in the assembly and the shell's at +26.250 and −25.750: two 0.600 mm bands
where one part's material has slid 3.5 mm and the other's has not. Nothing mates inside them —
every door-to-shell contact sits between 38 and 47 across — and in Y the two frames agree exactly.

Measured by cross-sectioning both meshes in the assembly frame at twelve heights from z = −0.45 to
z = 3.90:

| | upstream door, upstream shell | new door, stretched shell |
|---|---|---|
| outline crossings, all twelve heights | **0** | **0** |
| gap, hinge side | 0.300 mm | 0.300 mm |
| gap, latch side | 0.147 mm | 0.147 mm |
| gap at the anchors | — | 0.228 mm |

The seat is a flange: the door's outline is full size below z = −0.500 and the shell has no material
below it, so 2.00 mm of door stands proud of the shell's back face and the flange's top lands flush
on it. The MagSafe groove is inside that 2.00 mm and cannot foul the shell.

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

## Not done yet

- **The lens carriage has not been checked against the stretched shell**, nor the focus wheel
  against the carriage. The assembly frame and the method are both in hand, so those are the same
  job again with different files.
- The band arms and focus wheel are untouched, and should not need changing.
- The dot field is a clean hex field with one fade band at its edge. Upstream's is graded more
  gradually than that, and the two do not match hole for hole.
- **Nothing here has been printed.** Every number is measured off the meshes; none is measured off
  a part in hand.
