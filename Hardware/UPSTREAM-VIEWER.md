# Why the iPhone 18 Pro Max needs its own viewer

Measured from the published files of brenpoly's
[Mobile VR viewer for modern smartphones](https://makerworld.com/en/models/3511377-mobile-vr-viewer-for-modern-smartphones)
(CC BY-NC-SA), which ship print-ready STLs for the iPhone 15 Pro and Pixel 9 Pro plus STEP
sources. Nothing here is copied from them; these are measurements, recorded so the conclusion can
be checked rather than taken on trust.

## How that viewer is built

| Part | Size (mm) | Per phone? |
|---|---|---|
| Viewer shell | 102.70 × 162.16 × 121.98 | No |
| Lens carriage | 72.50 × 153.58 × 30.25 | No |
| Focus wheel | 26.0 × 26.0 × 10.5 | No |
| Knit band arm | — | No |
| **Door** | **89.49 × 159.18 × 6.50** | **Yes** |
| TPU corner locators ×4 | ~15.9 × 22.3 × 7.7 | **Yes** |

The door is the phone-specific part, and **both phones' doors have the same outer envelope** —
89.49 × 159.18 × 6.50 to the hundredth of a millimetre. Sectioning them shows they are identical
everywhere except one feature, the phone window at 2 mm above the outer face:

| Door | Phone body | Window at z = 2 |
|---|---|---|
| iPhone 15 Pro | 70.6 × 146.6 | 68.96 × 142.97 |
| Pixel 9 Pro | 72.0 × 152.8 | 70.70 × 149.46 |

So the window is the phone less about 1.5 mm across and 3.5 mm along — a lip that laps the bezel —
and the four TPU locators pack out the corners. Adding a phone means that window, those locators,
and a camera opening. Nothing else.

## Why that stops at the iPhone 18 Pro Max

**The phone is longer than the door.** The iPhone 18 Pro Max is **163.4 mm**; the door's whole
outer length is **159.18 mm**, and so is the shell's at the phone bay. There is no window to cut.

Allowing a 2 mm rim — thinner than anything else in the part — the longest window that door could
carry is about 155 mm, so the longest phone is about **158.6 mm**. The Pixel 9 Pro at 152.8 mm is
already close to it, with 3.19 mm of door each end. The 18 Pro Max is over by roughly 5 mm at the
most generous reading and about 8 mm in practice.

Width is not the problem: at 78.0 mm it would leave a 6.5 mm rim, which is comfortable.

**And the shell cannot simply be stretched.** Sectioning it along the phone's long axis shows the
cross-section changing at every step through the middle — the outline runs from X −38.85 at the
centre to −44.15 twenty millimetres out, and the height from 68.01 to 70.36. It is a contoured
shell, not an extrusion, so it cannot be cut in half and bridged to gain length. Lengthening it
means extending curved surfaces in CAD, on every part that spans the phone: shell, carriage and
band arms.

## What was worth taking from it

The lens spacing. The carriage's bores sit at y = ±32.2 mm, so its inter-lens distance is about
**64.4 mm** — within half a millimetre of the 63.9 mm that `ViewerParams.CardboardV2` declares and
that [`viewer.scad`](viewer.scad) is built around. That is a useful independent check on the
optical numbers this project's software uses.

It also does two things better than `viewer.scad` does, and both are worth stealing: a focus
**wheel** driving the carriage on a rack, where this design has a friction slide, and soft **TPU
corner locators**, which grip the phone and absorb the knocks a rigid pocket passes straight on.
